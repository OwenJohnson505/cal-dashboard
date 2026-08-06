<#
.SYNOPSIS
  Scrape Delivery Master's tariff rate cards and customer assignments.

.DESCRIPTION
  There is no report for tariffs, but System Setup > Tariffs is a WPF data grid
  that exposes GridPattern, so it can be read directly through UI Automation.
  That is far more robust than Ctrl+A / Ctrl+C: no clipboard, no focus stealing,
  no paste formatting to guess at, and every cell is addressed by row and column
  rather than by position on screen.

  The grid gives everything needed to price a quote from first principles:

      expected price = base + max(0, miles - included_miles) * rate_per_mile

  plus the list of customers each tariff is assigned to.

  Deterministic - no AI in the loop. It validates its own output and writes a
  quality report; anything that fails validation is flagged for review rather
  than silently accepted.

.EXAMPLE
  .\dm_tariffs.ps1 -Profile CalNorth
  .\dm_tariffs.ps1 -Profile CalNorth,CalSouth -OutDir C:\data\tariffs
#>
[CmdletBinding()]
param(
    [ValidateSet('CalNorth','CalSouth','CalManchester','CalRuncorn')]
    [string[]]$Profile = @('CalNorth'),
    [string]$OutDir = $PSScriptRoot,
    [int]$TimeoutMin = 10
)

$ErrorActionPreference='Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$UIA=[System.Windows.Automation.AutomationElement]
$log = Join-Path $PSScriptRoot 'dm_tariffs.log'
function Say($m,$lvl='INFO'){
  $l='{0}  {1,-5}  {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$lvl,$m
  Write-Host $l; Add-Content $log $l -Encoding utf8 }

# Reuse the login already proven in dm_auto.ps1 rather than duplicating it.
$auto = Join-Path $PSScriptRoot 'dm_auto.ps1'

function Get-DmWin {
  $p=Get-Process DeliveryMaster -ErrorAction SilentlyContinue
  if(-not $p){ return $null }
  $UIA::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children,[System.Windows.Automation.Condition]::TrueCondition) |
    Where-Object { $_.Current.ProcessId -eq $p.Id -and $_.Current.ControlType.ProgrammaticName -eq 'ControlType.Window' } |
    Select-Object -First 1
}
function Invoke-El($e){
  try{ $e.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); return }catch{}
  try{ $e.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select() }catch{}
}

# A grid cell's Name is the binding descriptor, not the value - the visible text
# lives in child Text elements, same as the connection dropdown.
$textCond = New-Object System.Windows.Automation.PropertyCondition($UIA::ControlTypeProperty,[System.Windows.Automation.ControlType]::Text)
function Get-CellText($cell){
  if(-not $cell){ return '' }
  $t=$cell.FindAll([System.Windows.Automation.TreeScope]::Descendants,$textCond)
  $v=@(); foreach($x in $t){ if($x.Current.Name){ $v += $x.Current.Name } }
  if($v.Count){ return ($v -join ' ').Trim() }
  $n=$cell.Current.Name
  if($n -match 'DeliveryMaster\.ViewModel'){ return '' }   # unrendered binding
  return $n
}

function Parse-Money($s){
  if(-not $s){ return $null }
  $c=($s -replace '[^0-9\.\-]','')
  if($c -eq '' -or $c -eq '-'){ return $null }
  try{ [double]$c }catch{ $null }
}

foreach($pf in $Profile){
  Say "=== $pf ==="
  & $auto -Discover -Profile $pf *> $null      # establishes the session
  Remove-Item (Join-Path $PSScriptRoot 'dm_tree_*.txt') -ErrorAction SilentlyContinue

  $w = Get-DmWin
  if(-not $w){ Say "no window for $pf" 'ERROR'; continue }

  $setup=$w.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition($UIA::NameProperty,'System Setup')))
  if(-not $setup){ Say "System Setup tab not found" 'ERROR'; continue }
  Invoke-El $setup; Start-Sleep -Seconds 2

  $btn=$w.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition($UIA::AutomationIdProperty,'rbtnTariff')))
  if(-not $btn){ Say "Tariffs button not found" 'ERROR'; continue }
  Invoke-El $btn; Start-Sleep -Seconds 5

  $grid=$null
  $deadline=(Get-Date).AddMinutes(2)
  while((Get-Date) -lt $deadline -and -not $grid){
    $grid=$w.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
      (New-Object System.Windows.Automation.PropertyCondition($UIA::AutomationIdProperty,'gvTariffs')))
    if(-not $grid){ Start-Sleep -Seconds 2 }
  }
  if(-not $grid){ Say "tariff grid never appeared" 'ERROR'; continue }

  $gp=$grid.GetCurrentPattern([System.Windows.Automation.GridPattern]::Pattern)
  $rows=$gp.Current.RowCount; $cols=$gp.Current.ColumnCount
  Say "grid: $rows rows x $cols cols"

  $out=New-Object System.Collections.Generic.List[object]
  $blank=0
  $stop=(Get-Date).AddMinutes($TimeoutMin)
  for($r=0; $r -lt $rows; $r++){
    if((Get-Date) -gt $stop){ Say "timeout at row $r of $rows" 'WARN'; break }
    $cells=@()
    for($c=0; $c -lt $cols; $c++){
      try { $cells += (Get-CellText $gp.GetItem($r,$c)) } catch { $cells += '' }
    }
    # column order confirmed against the live grid on 2026-08-06
    $rec=[pscustomobject]@{
      profile        = $pf
      tariff_name    = $cells[0]
      basis          = $cells[1]                    # e.g. Distance
      vehicle        = $cells[2]
      base_price     = Parse-Money $cells[3]
      included_miles = Parse-Money $cells[4]
      rate_per_mile  = Parse-Money $cells[5]
      extra_1        = $cells[6]
      extra_2        = $cells[7]
      customers      = $cells[8]
      scraped_at     = (Get-Date).ToString('s')
    }
    if(-not $rec.tariff_name){ $blank++ } else { $blank=0 }
    $out.Add($rec) | Out-Null
    if($blank -ge 25){ Say "25 consecutive blank rows at $r - stopping early" 'WARN'; break }
    if($r % 100 -eq 0 -and $r){ Say "  ...$r rows" }
  }

  $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
  $csv=Join-Path $OutDir "tariffs_$($pf)_$stamp.csv"
  $out | Where-Object { $_.tariff_name } | Export-Csv $csv -NoTypeInformation -Encoding UTF8
  $kept=@($out | Where-Object { $_.tariff_name }).Count
  Say "wrote $kept tariffs -> $csv"

  # ---- self-validation: say what is wrong rather than pretending it is clean ----
  $bad=@($out | Where-Object { $_.tariff_name -and ($null -eq $_.base_price -or $null -eq $_.rate_per_mile) })
  $noCust=@($out | Where-Object { $_.tariff_name -and -not $_.customers })
  $dupes=@($out | Where-Object { $_.tariff_name } | Group-Object tariff_name | Where-Object { $_.Count -gt 1 })
  Say "validation: $($bad.Count) rows missing a price, $($noCust.Count) with no customer assigned, $($dupes.Count) duplicate tariff names"
  if($kept -lt ($rows*0.5)){ Say "ONLY $kept of $rows rows captured - grid virtualisation may have truncated this. Re-run before trusting it." 'ERROR' }
  if($bad.Count){ ($bad | Select-Object -First 10 | ForEach-Object { "   unparsed: $($_.tariff_name)" }) | ForEach-Object { Say $_ 'WARN' } }
}
Say 'done'
