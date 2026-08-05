<#
.SYNOPSIS
  Drive Delivery Master's report screens without a human, via UI Automation.

.DESCRIPTION
  Delivery Master is a native WPF app with no API, CLI or scheduler, so reports
  have to be triggered through its UI. This does that by addressing controls
  through the Windows accessibility tree (names and automation IDs) rather than
  screen coordinates, so it survives the window being moved or resized.

  Passwords are read from Windows Credential Manager. They are never stored in
  this script, passed on a command line, or written to a log.

  Delivery Master closes itself after ~15 minutes idle, so each report is run
  against a freshly checked session and the app is relaunched when it has gone.

.EXAMPLE
  # One-time, per profile. Prompts securely; nothing is echoed.
  .\dm_auto.ps1 -StoreCredential CalNorth
  .\dm_auto.ps1 -StoreCredential CalSafe

.EXAMPLE
  # Dump the UI tree so report tiles and their Process buttons can be mapped.
  .\dm_auto.ps1 -Discover -Profile CalNorth

.EXAMPLE
  # Run yesterday's reports for both profiles.
  .\dm_auto.ps1 -Run -Profile CalNorth,CalSafe
#>
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(ParameterSetName = 'Store', Mandatory)]
    [ValidateSet('CalNorth', 'CalSafe')]
    [string]$StoreCredential,

    [Parameter(ParameterSetName = 'Discover', Mandatory)]
    [switch]$Discover,

    [Parameter(ParameterSetName = 'Run', Mandatory)]
    [switch]$Run,

    [Parameter(ParameterSetName = 'Discover')]
    [Parameter(ParameterSetName = 'Run')]
    [ValidateSet('CalNorth', 'CalSafe')]
    [string[]]$Profile = @('CalNorth', 'CalSafe'),

    # Defaults to yesterday, which is what the nightly run wants.
    [Parameter(ParameterSetName = 'Run')]
    [datetime]$From = (Get-Date).Date.AddDays(-1),

    [Parameter(ParameterSetName = 'Run')]
    [datetime]$To = (Get-Date).Date.AddDays(-1)
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

$Script:ExePath      = 'C:\Program Files (x86)\Delivery Master\Delivery Master\DeliveryMaster.exe'
$Script:ReportsRoot  = 'C:\Program Files (x86)\Delivery Master\Delivery Master\Reports'
$Script:LogPath      = Join-Path $PSScriptRoot 'dm_auto.log'

# The dropdown on the login screen shows a display name that differs from the
# short name we use everywhere else.
$Script:ProfileDisplayName = @{
    CalNorth = 'Customer Default'
    CalSafe  = 'CalSafe'
}

# Reports to run each night. 'Group' is the ribbon button, 'Tile' is the heading
# above the Process button, 'Folder' is where the export lands under Reports\.
$Script:ReportPlan = @(
    @{ Group = 'Booking Reports'; Tile = 'Booking Issues';             Folder = 'BookingIssues' }
    @{ Group = 'Booking Reports'; Tile = 'Response Time';              Folder = 'ResponseTime' }
    @{ Group = 'Booking Reports'; Tile = 'Productivity Summary Report'; Folder = 'ProductivitySummary' }
    @{ Group = 'Booking Reports'; Tile = 'Driver Allocation by User';  Folder = 'DriverAllocatorProfitReport' }
    @{ Group = 'Booking Reports'; Tile = 'Consignment Log';            Folder = 'ConsignmentLog' }
    @{ Group = 'Booking Reports'; Tile = 'User Login';                 Folder = 'UserProductivity' }
    @{ Group = 'Driver Reports';  Tile = 'Driver List';                Folder = 'DriverList' }
    @{ Group = 'Customer Reports'; Tile = 'Customer List';             Folder = 'CustomerList' }
)

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0}  {1,-5}  {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    Add-Content -Path $Script:LogPath -Value $line -Encoding utf8
}

#region Credential Manager -----------------------------------------------------
# P/Invoke rather than a third-party module so this needs no installs.
if (-not ('Win32.CredMan' -as [type])) {
    Add-Type -Namespace Win32 -Name CredMan -MemberDefinition @'
[StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
public struct CREDENTIAL {
    public uint Flags; public uint Type; public string TargetName; public string Comment;
    public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
    public uint CredentialBlobSize; public IntPtr CredentialBlob; public uint Persist;
    public uint AttributeCount; public IntPtr Attributes; public string TargetAlias; public string UserName;
}
[DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
public static extern bool CredReadW(string target, uint type, uint flags, out IntPtr credential);
[DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
public static extern bool CredWriteW(ref CREDENTIAL credential, uint flags);
[DllImport("advapi32.dll")] public static extern void CredFree(IntPtr buffer);
'@
}

function Get-DmCredential {
    param([Parameter(Mandatory)][string]$ProfileName)
    $target = "DeliveryMaster/$ProfileName"
    $ptr = [IntPtr]::Zero
    if (-not [Win32.CredMan]::CredReadW($target, 1, 0, [ref]$ptr)) {
        throw "No credential stored for '$target'. Run:  .\dm_auto.ps1 -StoreCredential $ProfileName"
    }
    try {
        $cred = [System.Runtime.InteropServices.Marshal]::PtrToStructure($ptr, [type][Win32.CredMan+CREDENTIAL])
        $password = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($cred.CredentialBlob, $cred.CredentialBlobSize / 2)
        [pscustomobject]@{ UserName = $cred.UserName; Password = $password }
    }
    finally { [Win32.CredMan]::CredFree($ptr) }
}

function Set-DmCredential {
    param([Parameter(Mandatory)][string]$ProfileName)
    $target = "DeliveryMaster/$ProfileName"
    Write-Host ""
    Write-Host "Storing the Delivery Master login for '$ProfileName'." -ForegroundColor Cyan
    Write-Host "This goes into Windows Credential Manager under: $target"
    Write-Host "The password is not shown, logged, or written to any file." -ForegroundColor DarkGray
    Write-Host ""
    $c = Get-Credential -Message "Delivery Master - $ProfileName ($($Script:ProfileDisplayName[$ProfileName]))"
    if (-not $c) { throw 'Cancelled.' }

    $plain = $c.GetNetworkCredential().Password
    $blob  = [System.Runtime.InteropServices.Marshal]::StringToCoTaskMemUni($plain)
    try {
        $cred = New-Object Win32.CredMan+CREDENTIAL
        $cred.Type               = 1        # CRED_TYPE_GENERIC
        $cred.TargetName         = $target
        $cred.UserName           = $c.UserName
        $cred.CredentialBlob     = $blob
        $cred.CredentialBlobSize = [System.Text.Encoding]::Unicode.GetByteCount($plain)
        $cred.Persist            = 2        # LOCAL_MACHINE, survives reboot
        if (-not [Win32.CredMan]::CredWriteW([ref]$cred, 0)) {
            throw "CredWrite failed (error $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error()))."
        }
        Write-Host "Stored '$target' for user '$($c.UserName)'." -ForegroundColor Green
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeCoTaskMemUnicode($blob)
        $plain = $null
    }
}
#endregion

#region UI Automation helpers --------------------------------------------------
$UIA = [System.Windows.Automation.AutomationElement]

function Get-DmWindow {
    param([int]$TimeoutSec = 60)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $p = Get-Process DeliveryMaster -ErrorAction SilentlyContinue
        if ($p) {
            $root = $UIA::RootElement
            $win = $root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition) |
                   Where-Object { $_.Current.ProcessId -eq $p.Id -and $_.Current.ControlType.ProgrammaticName -eq 'ControlType.Window' } |
                   Select-Object -First 1
            if ($win) { return $win }
        }
        Start-Sleep -Milliseconds 500
    }
    throw 'Delivery Master window did not appear.'
}

function Find-Element {
    param(
        [Parameter(Mandatory)]$Root,
        [string]$AutomationId,
        [string]$Name,
        [string]$ControlType,
        [int]$TimeoutSec = 20
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $conds = New-Object System.Collections.ArrayList
        if ($AutomationId) { [void]$conds.Add((New-Object System.Windows.Automation.PropertyCondition($UIA::AutomationIdProperty, $AutomationId))) }
        if ($Name)         { [void]$conds.Add((New-Object System.Windows.Automation.PropertyCondition($UIA::NameProperty, $Name))) }
        if ($ControlType)  { [void]$conds.Add((New-Object System.Windows.Automation.PropertyCondition($UIA::ControlTypeProperty, [System.Windows.Automation.ControlType]::$ControlType))) }
        $cond = if ($conds.Count -eq 1) { $conds[0] } else { New-Object System.Windows.Automation.AndCondition ([System.Windows.Automation.Condition[]]$conds.ToArray()) }
        $el = $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
        if ($el) { return $el }
        Start-Sleep -Milliseconds 400
    }
    return $null
}

function Invoke-Element {
    param([Parameter(Mandatory)]$Element)
    try {
        $p = $Element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
        $p.Invoke(); return
    } catch { }
    # Some WPF buttons expose Toggle/SelectionItem instead of Invoke.
    try {
        $p = $Element.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
        $p.Select(); return
    } catch { }
    throw "Element '$($Element.Current.Name)' exposes no invokable pattern."
}

function Set-ElementValue {
    <#
      The Search Criteria date boxes are segmented masked controls that ignore
      synthetic keystrokes entirely. ValuePattern writes them directly, which is
      the only reliable way to set a date.
    #>
    param([Parameter(Mandatory)]$Element, [Parameter(Mandatory)][string]$Value)
    $p = $Element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    if ($p.Current.IsReadOnly) { throw 'Value is read-only.' }
    $p.SetValue($Value)
}
#endregion

#region Login ------------------------------------------------------------------
function Connect-DeliveryMaster {
    param([Parameter(Mandatory)][string]$ProfileName)

    if (-not (Get-Process DeliveryMaster -ErrorAction SilentlyContinue)) {
        Write-Log "Launching Delivery Master for $ProfileName"
        Start-Process $Script:ExePath | Out-Null
    }
    $win = Get-DmWindow

    # Already signed in? The login screen has btnLogin; the main shell does not.
    $loginBtn = Find-Element -Root $win -AutomationId 'btnLogin' -TimeoutSec 8
    if (-not $loginBtn) {
        Write-Log "Session already active for $ProfileName"
        return $win
    }

    $cred = Get-DmCredential -ProfileName $ProfileName

    $combo = Find-Element -Root $win -AutomationId 'cmbConnections'
    if ($combo) {
        $display = $Script:ProfileDisplayName[$ProfileName]
        $expand = $combo.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
        $expand.Expand(); Start-Sleep -Milliseconds 400
        $item = Find-Element -Root $combo -Name $display -TimeoutSec 8
        if (-not $item) { $expand.Collapse(); throw "Profile '$display' not found in the connection dropdown." }
        Invoke-Element $item
        Start-Sleep -Milliseconds 400
        Write-Log "Selected connection '$display'"
    }

    $u = Find-Element -Root $win -AutomationId 'txtUserName'
    $p = Find-Element -Root $win -AutomationId 'txtPassword'
    Set-ElementValue -Element $u -Value $cred.UserName
    Set-ElementValue -Element $p -Value $cred.Password
    $cred = $null

    Invoke-Element $loginBtn
    Write-Log "Signed in as $($ProfileName)"

    # Wait for the shell: the login button disappears once authenticated.
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        if (-not (Find-Element -Root (Get-DmWindow) -AutomationId 'btnLogin' -TimeoutSec 2)) { return Get-DmWindow }
        Start-Sleep -Seconds 1
    }
    $err = Find-Element -Root (Get-DmWindow) -AutomationId 'lblError' -TimeoutSec 2
    throw "Login did not complete for $ProfileName. $(if ($err) { $err.Current.Name })"
}
#endregion

#region Report run -------------------------------------------------------------
function Invoke-DmReport {
    param(
        [Parameter(Mandatory)]$Window,
        [Parameter(Mandatory)][hashtable]$Report,
        [Parameter(Mandatory)][datetime]$From,
        [Parameter(Mandatory)][datetime]$To
    )

    $before = @(Get-ChildItem (Join-Path $Script:ReportsRoot $Report.Folder) -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notlike '~$*' } | Select-Object -ExpandProperty FullName)

    $tab = Find-Element -Root $Window -Name 'Reports' -ControlType TabItem
    if ($tab) { Invoke-Element $tab; Start-Sleep -Milliseconds 800 }

    $group = Find-Element -Root $Window -Name $Report.Group
    if (-not $group) { throw "Report group '$($Report.Group)' not found." }
    Invoke-Element $group; Start-Sleep -Milliseconds 1200

    # Each tile is a group box titled with the report name; its Process button is
    # the only invokable child, so scope the search to the tile to stay unambiguous.
    $tile = Find-Element -Root $Window -Name $Report.Tile
    if (-not $tile) { throw "Report tile '$($Report.Tile)' not found in '$($Report.Group)'." }
    $process = Find-Element -Root $tile -Name 'Process' -ControlType Button
    if (-not $process) { throw "No Process button under tile '$($Report.Tile)'." }
    Invoke-Element $process
    Write-Log "Opened '$($Report.Tile)'"

    $dialog = Find-Element -Root (Get-DmWindow) -Name 'Search Criteria' -TimeoutSec 25
    if (-not $dialog) { throw "Search Criteria dialog did not open for '$($Report.Tile)'." }
    Start-Sleep -Milliseconds 600

    # All customers, where the report offers it.
    $all = Find-Element -Root $dialog -Name 'All' -ControlType CheckBox -TimeoutSec 4
    if ($all) {
        $t = $all.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
        if ($t.Current.ToggleState -ne 'On') { $t.Toggle() }
    }

    # Dates, via ValuePattern - typing does not work on these controls.
    $edits = @($dialog.FindAll([System.Windows.Automation.TreeScope]::Descendants,
              (New-Object System.Windows.Automation.PropertyCondition($UIA::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit))))
    $dateEdits = @($edits | Where-Object { $_.Current.Name -match 'From|To' -or $_.Current.AutomationId -match 'From|To|Date' })
    if ($dateEdits.Count -lt 2) { $dateEdits = $edits }   # fall back to positional
    if ($dateEdits.Count -ge 2) {
        try {
            Set-ElementValue -Element $dateEdits[0] -Value $From.ToString('dd-MM-yyyy')
            Set-ElementValue -Element $dateEdits[1] -Value $To.ToString('dd-MM-yyyy')
            Write-Log ("Date range {0} to {1}" -f $From.ToString('dd-MM-yyyy'), $To.ToString('dd-MM-yyyy'))
        } catch {
            Write-Log "Could not set dates on '$($Report.Tile)' ($_). Using the dialog default." 'WARN'
        }
    }

    $export = Find-Element -Root $dialog -Name 'Export' -ControlType Button
    if (-not $export) { throw "No Export button on the Search Criteria dialog." }
    Invoke-Element $export
    Write-Log "Exporting '$($Report.Tile)'..."

    # Wait for a new file rather than a fixed sleep - run times vary wildly.
    $deadline = (Get-Date).AddMinutes(10)
    while ((Get-Date) -lt $deadline) {
        $now = @(Get-ChildItem (Join-Path $Script:ReportsRoot $Report.Folder) -File -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -notlike '~$*' } | Select-Object -ExpandProperty FullName)
        $new = $now | Where-Object { $_ -notin $before }
        if ($new) {
            Start-Sleep -Seconds 2   # let the write settle
            Write-Log "Wrote $(Split-Path $new[0] -Leaf)"
            return $new[0]
        }
        Start-Sleep -Seconds 3
    }
    throw "'$($Report.Tile)' produced no file within 10 minutes."
}
#endregion

#region Discovery --------------------------------------------------------------
function Show-DmTree {
    param([Parameter(Mandatory)]$Window, [int]$MaxDepth = 6)
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $out = New-Object System.Collections.ArrayList
    function Walk($el, $depth) {
        if ($depth -gt $MaxDepth) { return }
        $c = $walker.GetFirstChild($el)
        while ($c) {
            $ct = $c.Current.ControlType.ProgrammaticName -replace 'ControlType\.', ''
            if ($c.Current.Name -or $c.Current.AutomationId) {
                [void]$out.Add(('{0}[{1}] "{2}" id={3}' -f ('  ' * $depth), $ct, $c.Current.Name, $c.Current.AutomationId))
            }
            Walk $c ($depth + 1)
            $c = $walker.GetNextSibling($c)
        }
    }
    Walk $Window 0
    $path = Join-Path $PSScriptRoot ('dm_tree_{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $out | Set-Content -Path $path -Encoding utf8
    Write-Log "UI tree written to $path ($($out.Count) elements)"
    $out | Select-Object -First 120
}
#endregion

# ---- entry points -------------------------------------------------------------
switch ($PSCmdlet.ParameterSetName) {

    'Store' { Set-DmCredential -ProfileName $StoreCredential; break }

    'Discover' {
        foreach ($pf in $Profile) {
            $win = Connect-DeliveryMaster -ProfileName $pf
            $tab = Find-Element -Root $win -Name 'Reports' -ControlType TabItem
            if ($tab) { Invoke-Element $tab; Start-Sleep -Seconds 2 }
            Show-DmTree -Window (Get-DmWindow)
        }
        break
    }

    'Run' {
        Write-Log "=== nightly run: $($From.ToString('yyyy-MM-dd')) to $($To.ToString('yyyy-MM-dd')) ==="
        $ok = 0; $failed = @()
        foreach ($pf in $Profile) {
            foreach ($r in $Script:ReportPlan) {
                try {
                    # Delivery Master closes itself after ~15 min idle, so re-establish
                    # the session before every report rather than assuming it survived.
                    $win = Connect-DeliveryMaster -ProfileName $pf
                    Invoke-DmReport -Window $win -Report $r -From $From -To $To | Out-Null
                    $ok++
                }
                catch {
                    Write-Log "FAILED $pf / $($r.Tile): $_" 'ERROR'
                    $failed += "$pf / $($r.Tile)"
                    # A failed report often leaves a modal open; close the app so the
                    # next iteration starts from a known state.
                    Get-Process DeliveryMaster -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 3
                }
            }
        }
        Write-Log "=== done: $ok succeeded, $($failed.Count) failed ==="
        if ($failed) { Write-Log ("failed: {0}" -f ($failed -join '; ')) 'WARN'; exit 1 }
        break
    }
}
