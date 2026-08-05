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
  .\dm_auto.ps1 -StoreCredential CalSouth

.EXAMPLE
  # Dump the UI tree so report tiles and their Process buttons can be mapped.
  .\dm_auto.ps1 -Discover -Profile CalNorth

.EXAMPLE
  # Run yesterday's reports for both profiles.
  .\dm_auto.ps1 -Run -Profile CalNorth,CalSouth
#>
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(ParameterSetName = 'Store', Mandatory)]
    [ValidateSet('CalNorth', 'CalSouth', 'CalManchester', 'CalRuncorn')]
    [string]$StoreCredential,

    [Parameter(ParameterSetName = 'Discover', Mandatory)]
    [switch]$Discover,

    [Parameter(ParameterSetName = 'Run', Mandatory)]
    [switch]$Run,

    [Parameter(ParameterSetName = 'Discover')]
    [Parameter(ParameterSetName = 'Run')]
    [ValidateSet('CalNorth', 'CalSouth', 'CalManchester', 'CalRuncorn')]
    [string[]]$Profile = @('CalNorth', 'CalSouth'),

    # Defaults to yesterday, which is what the nightly run wants.
    [Parameter(ParameterSetName = 'Run')]
    [datetime]$From = (Get-Date).Date.AddDays(-1),

    [Parameter(ParameterSetName = 'Run')]
    [datetime]$To = (Get-Date).Date.AddDays(-1),

    # Run only these tiles, for testing a single report without the whole plan.
    [Parameter(ParameterSetName = 'Run')]
    [string[]]$Only,

    # A report that never produces a file must not stall the whole night.
    [Parameter(ParameterSetName = 'Run')]
    [int]$ReportTimeoutMin = 4,

    # Hard stop for the entire run, so an unattended job cannot run until morning.
    [Parameter(ParameterSetName = 'Run')]
    [int]$MaxRunMin = 90
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

$Script:ExePath      = 'C:\Program Files (x86)\Delivery Master\Delivery Master\DeliveryMaster.exe'
$Script:ReportsRoot  = 'C:\Program Files (x86)\Delivery Master\Delivery Master\Reports'
$Script:LogPath      = Join-Path $PSScriptRoot 'dm_auto.log'

# Short name -> the label shown in the login screen's connection dropdown.
# Read directly off the live control on 2026-08-05; the dropdown has exactly
# these four entries and nothing else. 'Default' is the North business - the
# window title reads "Cal (North)" once signed in on it.
$Script:ProfileDisplayName = @{
    CalNorth      = 'Default'
    CalSouth      = 'Cal South'
    CalManchester = 'Cal Manchester'
    CalRuncorn    = 'Cal Runcorn'
}

# Reports to run each night. 'Group' is the ribbon button, 'Tile' is the heading
# above the Process button.
#
# This is deliberately NOT every tile in the app. Excluded on purpose:
#   * Document producers - Customer Invoice, Credit Note, Proforma, Driver
#     Invoice/Remittance/Self Bill, Delivery Note, CMR, Manifest, labels, RAMS.
#     These generate real financial or operational paperwork, not analysis.
#   * Email senders - Email POD.
#   * Accounting exports - Xero / Sage / QuickBooks. These typically mark records
#     as exported, which would corrupt the real accounts workflow.
#   * Single-customer reports - Wincanton, Calea, HSS, DHL, Fedex, Millers,
#     Alternergy, Skipton, Octopus. Add individually if wanted.
# Everything below is a read-only data export.
$Script:ReportPlan = @(
    # VERIFIED end to end against the live app on 2026-08-06: each of these
    # writes a spreadsheet into Reports\ without further prompting.
    @{ Group = 'Booking Reports';  Tile = 'Booking Issues' }
    @{ Group = 'Booking Reports';  Tile = 'Response Time' }
    @{ Group = 'Booking Reports';  Tile = 'Productivity Summary Report' }
    @{ Group = 'Booking Reports';  Tile = 'Driver Allocation by User' }
    @{ Group = 'Booking Reports';  Tile = 'Consignment Log' }
)

# Tried and NOT working yet - deliberately left out of the nightly run so it
# does not spend an hour failing. Each opens fine but never writes a file, or
# presents a differently shaped dialog:
#   Booking Reports  : User Login, Quote Conversion, Non-Converted Quotes,
#                      Cancelled Bookings, Gross Margin, Customer Data
#   Driver Reports   : Driver List (no Search Criteria dialog at all)
#   Customer Reports : Customer List
#   Account Reports  : Aged Debtors (no Export button), Dashboard Report
# Likely cause: these render to a preview/Save-As path rather than writing
# straight to Reports\. Needs watching by hand once to see what they actually do.

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
function Set-DatePicker {
    <#
      Sets one of the Search Criteria date boxes. Tries the known automation IDs
      first, then falls back to any DatePicker-classed element in document order,
      since a few dialogs name theirs differently. Returns $true on success.
    #>
    param(
        [Parameter(Mandatory)]$Dialog,
        [Parameter(Mandatory)][string[]]$Ids,
        [Parameter(Mandatory)][datetime]$Date
    )
    foreach ($id in $Ids) {
        $el = $Dialog.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
              (New-Object System.Windows.Automation.PropertyCondition($UIA::AutomationIdProperty, $id)))
        if (-not $el) { continue }
        try {
            $vp = $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
            if ($vp.Current.IsReadOnly) { continue }
            $vp.SetValue($Date.ToString('dd-MM-yyyy'))
            Start-Sleep -Milliseconds 250
            return $true
        }
        catch { }
    }
    return $false
}

function Resolve-ReportTypeDialog {
    <#
      Several reports interrupt with a "Report Type" modal (PDF / Excel, then
      Continue) before the Search Criteria dialog appears - and for a few it
      appears again after Export. Always choose Excel: the whole pipeline parses
      spreadsheets, and a PDF export would land a file we cannot read.
      Returns $true if a dialog was handled.
    #>
    param([int]$TimeoutSec = 6)
    $dlg = Find-DmDialog -Title 'Report Type' -TimeoutSec $TimeoutSec
    if (-not $dlg) { return $false }
    $excel = $dlg.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
             (New-Object System.Windows.Automation.PropertyCondition($UIA::AutomationIdProperty, 'rbtnExcel')))
    if ($excel) {
        try { $excel.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select() } catch { }
        Start-Sleep -Milliseconds 250
    }
    $ok = $dlg.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
          (New-Object System.Windows.Automation.PropertyCondition($UIA::AutomationIdProperty, 'btnOK')))
    if (-not $ok) { throw 'Report Type dialog has no Continue button.' }
    Invoke-Element $ok
    Write-Log 'Report Type: chose Excel'
    Start-Sleep -Milliseconds 800
    return $true
}

function Find-DmDialog {
    <#
      The Search Criteria dialog is its own top-level window owned by the app,
      not a descendant of the main window, so it has to be found from the desktop
      root filtered to the Delivery Master process.
    #>
    param([Parameter(Mandatory)][string]$Title, [int]$TimeoutSec = 30)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $proc = Get-Process DeliveryMaster -ErrorAction SilentlyContinue
        if ($proc) {
            $hit = $UIA::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition) |
                   Where-Object { $_.Current.ProcessId -eq $proc.Id -and $_.Current.Name -eq $Title } |
                   Select-Object -First 1
            if ($hit) { return $hit }
        }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

function Wait-DmState {
    <#
      Returns @{State='Login'|'Shell'; Window=<element>} once the app has
      positively rendered one or the other. Both markers are checked on a fresh
      window handle each pass, because the window we get immediately after launch
      is not necessarily the one that ends up hosting the login form.
    #>
    param([int]$TimeoutSec = 90)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $win = $null
        try { $win = Get-DmWindow -TimeoutSec 5 } catch { }
        if ($win) {
            $login = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
                     (New-Object System.Windows.Automation.PropertyCondition($UIA::AutomationIdProperty, 'btnLogin')))
            if ($login) { return @{ State = 'Login'; Window = $win } }
            # tbReport is the Reports ribbon tab - only present once authenticated.
            $shell = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
                     (New-Object System.Windows.Automation.PropertyCondition($UIA::AutomationIdProperty, 'tbReport')))
            if ($shell) { return @{ State = 'Shell'; Window = $win } }
        }
        Start-Sleep -Milliseconds 700
    }
    throw "Delivery Master showed neither the login screen nor the main shell within $TimeoutSec seconds."
}

function Select-Connection {
    <#
      The connection dropdown's ListItems are all named after their bound class
      ("DeliveryMaster.CustomerConnection"); the visible label lives in a child
      Text element. So searching the dropdown by name finds the *label*, which is
      not selectable. Match on the child text, then select the owning ListItem.
    #>
    param([Parameter(Mandatory)]$Combo, [Parameter(Mandatory)][string]$Display)

    $expand = $Combo.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
    $expand.Expand()
    Start-Sleep -Milliseconds 700
    try {
        $items = @($Combo.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                  (New-Object System.Windows.Automation.PropertyCondition($UIA::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem))))
        $textCond = New-Object System.Windows.Automation.PropertyCondition($UIA::ControlTypeProperty, [System.Windows.Automation.ControlType]::Text)

        $found = $null
        $seen  = @()
        foreach ($it in $items) {
            $labels = @($it.FindAll([System.Windows.Automation.TreeScope]::Descendants, $textCond) |
                        ForEach-Object { $_.Current.Name } | Where-Object { $_ })
            $seen += $labels
            if ($labels -contains $Display) { $found = $it; break }
        }
        if (-not $found) {
            throw "Connection '$Display' is not in the dropdown. Available: $($seen -join ', ')"
        }
        $found.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
        Start-Sleep -Milliseconds 500
        Write-Log "Selected connection '$Display'"
    }
    catch {
        try { $expand.Collapse() } catch { }
        throw
    }
}

function Connect-DeliveryMaster {
    param([Parameter(Mandatory)][string]$ProfileName)

    if (-not (Get-Process DeliveryMaster -ErrorAction SilentlyContinue)) {
        Write-Log "Launching Delivery Master for $ProfileName"
        Start-Process $Script:ExePath | Out-Null
    }
    # Do NOT infer "signed in" from the absence of the login button: straight
    # after launch the window exists but nothing is rendered yet, so that test
    # silently reports a live session while sitting on the login screen. Poll
    # until one of the two states positively identifies itself.
    $state = Wait-DmState -TimeoutSec 90
    if ($state.State -eq 'Shell') {
        Write-Log "Session already active for $ProfileName"
        return $state.Window
    }
    $win = $state.Window

    $cred = Get-DmCredential -ProfileName $ProfileName

    $combo = Find-Element -Root $win -AutomationId 'cmbConnections'
    if ($combo) {
        Select-Connection -Combo $combo -Display $Script:ProfileDisplayName[$ProfileName]
    }

    # Re-acquire the window: expanding the connection dropdown re-templates part
    # of the login form, which invalidates element handles taken before it.
    $win = Get-DmWindow
    $u = Find-Element -Root $win -AutomationId 'txtUserName' -TimeoutSec 20
    $p = Find-Element -Root $win -AutomationId 'txtPassword' -TimeoutSec 20
    if (-not $u -or -not $p) { throw "Login fields not found for $ProfileName after selecting the connection." }
    Set-ElementValue -Element $u -Value $cred.UserName
    Set-ElementValue -Element $p -Value $cred.Password
    $cred = $null

    $loginBtn = Find-Element -Root $win -AutomationId 'btnLogin' -TimeoutSec 20
    if (-not $loginBtn) { throw "Login button vanished for $ProfileName." }
    Invoke-Element $loginBtn
    Write-Log "Signed in as $($ProfileName)"

    # Wait for the ribbon to appear rather than for the login button to vanish -
    # a rejected password leaves the form up with lblError populated.
    try {
        $after = Wait-DmState -TimeoutSec 90
        if ($after.State -eq 'Shell') { return $after.Window }
    } catch { }

    $err = Find-Element -Root (Get-DmWindow) -AutomationId 'lblError' -TimeoutSec 3
    $msg = if ($err -and $err.Current.Name) { $err.Current.Name } else { 'no error message shown' }
    throw "Login failed for $ProfileName ($($Script:ProfileDisplayName[$ProfileName])): $msg"
}
#endregion

#region Report run -------------------------------------------------------------
function Invoke-DmReport {
    param(
        [Parameter(Mandatory)]$Window,
        [Parameter(Mandatory)][hashtable]$Report,
        [Parameter(Mandatory)][datetime]$From,
        [Parameter(Mandatory)][datetime]$To,
        [int]$TimeoutMin = 4
    )

    # Watch the whole Reports tree, not just the folder we expect. Delivery
    # Master's output folder names do not always match the tile name, and a
    # wrong guess would otherwise look like a timeout.
    $before = @(Get-ChildItem $Script:ReportsRoot -Recurse -File -ErrorAction SilentlyContinue |
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

    # Some reports ask for PDF/Excel before showing the criteria dialog.
    [void](Resolve-ReportTypeDialog -TimeoutSec 6)

    $dialog = Find-DmDialog -Title 'Search Criteria' -TimeoutSec 30
    if (-not $dialog) { throw "Search Criteria dialog did not open for '$($Report.Tile)'." }
    Start-Sleep -Milliseconds 600

    # All customers, where the report offers it.
    $all = Find-Element -Root $dialog -Name 'All' -ControlType CheckBox -TimeoutSec 4
    if ($all) {
        $t = $all.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
        if ($t.Current.ToggleState -ne 'On') { $t.Toggle() }
    }

    # Dates. Target the DatePicker itself (dDateFrom / dDateTo), NOT the Edit
    # descendant - the inner PART_TextBox is read-only, and typing into it does
    # nothing. The DatePicker exposes a writable ValuePattern taking dd-MM-yyyy.
    $setFrom = Set-DatePicker -Dialog $dialog -Ids @('dDateFrom', 'dtpFrom', 'dpFrom') -Date $From
    $setTo   = Set-DatePicker -Dialog $dialog -Ids @('dDateTo',   'dtpTo',   'dpTo')   -Date $To
    if ($setFrom -and $setTo) {
        Write-Log ("Date range {0} to {1}" -f $From.ToString('dd-MM-yyyy'), $To.ToString('dd-MM-yyyy'))
    }
    else {
        Write-Log "Could not set both dates on '$($Report.Tile)' - using the dialog default range." 'WARN'
    }

    $export = Find-Element -Root $dialog -Name 'Export' -ControlType Button
    if (-not $export) { throw "No Export button on the Search Criteria dialog." }
    Invoke-Element $export
    Write-Log "Exporting '$($Report.Tile)'..."

    # ...and some ask only after Export is pressed.
    [void](Resolve-ReportTypeDialog -TimeoutSec 6)

    # Wait for a new file rather than a fixed sleep - run times vary wildly.
    $deadline = (Get-Date).AddMinutes($TimeoutMin)
    while ((Get-Date) -lt $deadline) {
        # Must mirror the $before snapshot exactly - same root, same recursion.
        $now = @(Get-ChildItem $Script:ReportsRoot -Recurse -File -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -notlike '~$*' } | Select-Object -ExpandProperty FullName)
        $new = @($now | Where-Object { $_ -notin $before })
        if ($new.Count) {
            Start-Sleep -Seconds 2   # let the write settle
            Write-Log "Wrote $(Split-Path $new[0] -Leaf)"
            return $new[0]
        }
        Start-Sleep -Seconds 3
    }
    throw "'$($Report.Tile)' produced no file within $TimeoutMin minutes."
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
        $plan = if ($Only) { @($Script:ReportPlan | Where-Object { $Only -contains $_.Tile }) } else { $Script:ReportPlan }
        if (-not $plan) { throw "No reports matched -Only: $($Only -join ', ')" }
        Write-Log "=== run: $($From.ToString('yyyy-MM-dd')) to $($To.ToString('yyyy-MM-dd')), $(@($plan).Count) report(s) x $($Profile.Count) profile(s) ==="
        $ok = 0; $failed = @()
        $runDeadline = (Get-Date).AddMinutes($MaxRunMin)
        foreach ($pf in $Profile) {
            foreach ($r in $plan) {
                try {
                    # Delivery Master closes itself after ~15 min idle, so re-establish
                    # the session before every report rather than assuming it survived.
                    if ((Get-Date) -gt $runDeadline) {
                        Write-Log "Overall run limit of $MaxRunMin min reached - skipping the rest." 'WARN'
                        $failed += "$pf / $($r.Tile) (skipped: run limit)"
                        continue
                    }
                    $win = Connect-DeliveryMaster -ProfileName $pf
                    Invoke-DmReport -Window $win -Report $r -From $From -To $To -TimeoutMin $ReportTimeoutMin | Out-Null
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
