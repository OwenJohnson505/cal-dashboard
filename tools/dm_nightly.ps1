<#
.SYNOPSIS
  Nightly Delivery Master run: pull yesterday's reports, ingest them, email a summary.

.DESCRIPTION
  Three steps, each independent so a failure in one is reported rather than
  silently swallowed:
    1. dm_auto.ps1  - drive the Delivery Master UI and export the reports
    2. dm_ingest.py - push the new files into Supabase
    3. Outlook      - email the run summary with the exports attached

  Nothing here handles a password directly. Delivery Master credentials come
  from Windows Credential Manager; Supabase reads SUPABASE_SERVICE_KEY from the
  machine environment.

.EXAMPLE
  .\dm_nightly.ps1                      # run it now, for yesterday
  .\dm_nightly.ps1 -SkipEmail           # run without emailing
  .\dm_nightly.ps1 -RegisterSchedule    # install the 10pm nightly task
#>
[CmdletBinding()]
param(
    [datetime]$Date = (Get-Date).Date.AddDays(-1),
    [string[]]$Profile = @('CalNorth', 'CalSouth'),
    [string]$MailTo = 'owen@cal.delivery',
    [switch]$SkipEmail,
    [switch]$SkipIngest,
    [switch]$RegisterSchedule
)

$ErrorActionPreference = 'Stop'
$here    = $PSScriptRoot
$logPath = Join-Path $here 'dm_nightly.log'
$reports = 'C:\Program Files (x86)\Delivery Master\Delivery Master\Reports'

function Log { param($m, $lvl = 'INFO')
    $line = '{0}  {1,-5}  {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $lvl, $m
    Write-Host $line; Add-Content $logPath $line -Encoding utf8
}

if ($RegisterSchedule) {
    # Runs whether or not Owen is logged in would need a stored password, so this
    # deliberately runs only in his interactive session - the UI automation needs
    # a desktop to drive anyway.
    $action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
               -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $here 'dm_nightly.ps1')`""
    $trigger = New-ScheduledTaskTrigger -Daily -At 22:00
    $set     = New-ScheduledTaskSettingsSet -StartWhenAvailable -WakeToRun `
               -ExecutionTimeLimit (New-TimeSpan -Hours 3) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName 'Cal - Delivery Master nightly reports' `
        -Action $action -Trigger $trigger -Settings $set -Description 'Export DM reports, ingest to Supabase, email summary.' -Force | Out-Null
    Log 'Registered scheduled task "Cal - Delivery Master nightly reports" for 22:00 daily.'
    return
}

Log "=== nightly start, date $($Date.ToString('yyyy-MM-dd')), profiles: $($Profile -join ', ') ==="
$started  = Get-Date
$problems = @()

# 1. Export -------------------------------------------------------------------
try {
    & (Join-Path $here 'dm_auto.ps1') -Run -Profile $Profile -From $Date -To $Date
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { $problems += 'Some reports failed to export (see dm_auto.log).' }
    Log 'Export step finished.'
}
catch { $problems += "Export step failed: $_"; Log "Export step failed: $_" 'ERROR' }

# Whatever landed while we were running, regardless of individual failures.
$new = @(Get-ChildItem $reports -Recurse -File -ErrorAction SilentlyContinue |
         Where-Object { $_.LastWriteTime -ge $started -and $_.Name -notlike '~$*' })
Log "New export files: $($new.Count)"

# 2. Ingest -------------------------------------------------------------------
if (-not $SkipIngest) {
    try {
        if (-not $env:SUPABASE_SERVICE_KEY) { throw 'SUPABASE_SERVICE_KEY is not set for this account.' }
        $out = & python (Join-Path $here 'dm_ingest.py') 2>&1
        $out | ForEach-Object { Log "ingest: $_" }
        Log 'Ingest step finished.'
    }
    catch { $problems += "Ingest step failed: $_"; Log "Ingest step failed: $_" 'ERROR' }
}

# 3. Email --------------------------------------------------------------------
if (-not $SkipEmail) {
    try {
        $status = if ($problems) { 'ATTENTION' } else { 'OK' }
        $body = @()
        $body += "Delivery Master nightly run - $status"
        $body += "Data date : $($Date.ToString('dd/MM/yyyy'))"
        $body += "Profiles  : $($Profile -join ', ')"
        $body += "Duration  : {0:n1} min" -f ((Get-Date) - $started).TotalMinutes
        $body += ''
        $body += "Files exported ($($new.Count)):"
        if ($new) { $new | ForEach-Object { $body += "  - $($_.Name)  ($([math]::Round($_.Length/1KB)) KB)" } }
        else      { $body += '  (none - the export step produced nothing)' }
        if ($problems) { $body += ''; $body += 'Problems:'; $problems | ForEach-Object { $body += "  - $_" } }

        $ol   = New-Object -ComObject Outlook.Application
        $mail = $ol.CreateItem(0)
        $mail.To      = $MailTo
        $mail.Subject = "DM nightly $($Date.ToString('dd/MM/yyyy')) - $status - $($new.Count) reports"
        $mail.Body    = ($body -join "`r`n")
        # Outlook rejects very large attachments; skip anything over 15 MB.
        foreach ($f in $new) {
            if ($f.Length -lt 15MB) { $null = $mail.Attachments.Add($f.FullName) }
            else { Log "Skipped attachment (too large): $($f.Name)" 'WARN' }
        }
        $mail.Send()
        Log "Emailed $MailTo with $($new.Count) attachment(s)."
    }
    catch { Log "Email step failed: $_" 'ERROR' }
}

Log "=== nightly end ($(if ($problems) { 'with problems' } else { 'clean' })) ==="
if ($problems) { exit 1 }
