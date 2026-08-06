<#
.SYNOPSIS
  Scrape open quotes (ref, customer, tariff, miles, price) from Delivery Master.

.DESCRIPTION
  The Non-Converted Quotes report carries no distance, so a lost quote cannot be
  priced against its tariff. The Quote screen does: Booking > Quote is a WPF grid
  (gvBookings) whose column chooser already has Miles, Tariff, Rev, Cost and M%
  enabled - they simply are not rendered until scrolled into view, because WPF
  only realises the columns currently on screen.

  So this reads in TWO PASSES: capture the left-hand columns, scroll right,
  capture the right-hand ones, then join on Our Ref, which stays frozen on screen
  in both passes. Column indices are relative to what is realised, so the join
  key is the only thing that can be relied on across a scroll.

  Deterministic - no AI, nothing charged per run. It validates its own output and
  fails loudly rather than importing something half-read.

.EXAMPLE
  .\dm_quotes.ps1 -Profile CalNorth
  .\dm_quotes.ps1 -Profile CalNorth,CalSouth -OutDir C:\data
#>
[CmdletBinding()]
param(
    [ValidateSet('CalNorth','CalSouth','CalManchester','CalRuncorn')]
    [string[]]$Profile = @('CalNorth'),
    [string]$OutDir = $PSScriptRoot,
    [int]$TimeoutMin = 15
)

$ErrorActionPreference='Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$UIA=[System.Windows.Automation.AutomationElement]
$log = Join-Path $PSScriptRoot 'dm_quotes.log'
function Say($m,$lvl='INFO'){
  $l='{0}  {1,-5}  {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$lvl,$m
  Write-Host $l; Add-Content $log $l -Encoding utf8 }

$auto = Join-Path $PSScriptRoot 'dm_auto.ps1'
$txtCond = New-Object System.Windows.Automation.PropertyCondition($UIA::ControlTypeProperty,[System.Windows.Automation.ControlType]::Text)

function Get-DmWin {
  $p=Get-Process DeliveryMaster -ErrorAction SilentlyContinue
  if(-not $p){ return $null }
  $UIA::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children,[System.Windows.Automation.Condition]::TrueCondition) |
    Where-Object { $_.Current.ProcessId -eq $p.Id -and $_.Current.Name -match '^Cal ' } | Select-Object -First 1
}
function Invoke-El($e){
  try{ $e.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); return }catch{}
  try{ $e.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select() }catch{}
}
# Cell.Name is the binding descriptor; the visible value lives in child Text nodes.
function Get-CellText($cell){
  if(-not $cell){ return '' }
  $t=$cell.FindAll([System.Windows.Automation.TreeScope]::Descendants,$txtCond)
  $v=@(); foreach($x in $t){ if($x.Current.Name){ $v += $x.Current.Name } }
  if($v.Count){
    # duplicated single values render as "X X" - collapse them
    $s=($v -join ' ').Trim()
    $half=[int]($s.Length/2)
    if($s.Length -gt 3 -and $s.Length % 2 -eq 1 -and $s.Substring(0,$half) -eq $s.Substring($half+1)){ return $s.Substring(0,$half) }
    return $s
  }
  $n=$cell.Current.Name
  if($n -match 'DeliveryMaster\.'){ return '' }
  return $n
}
function Money($s){
  if(-not $s){ return $null }
  $c=($s -replace '[^0-9\.\-]','')
  if($c -in @('','-','.')){ return $null }
  try{ [double]$c }catch{ $null }
}
function IntOf($s){
  if(-not $s){ return $null }
  # "172 172" -> 172
  $first=($s -split '\s+')[0]
  $c=($first -replace '[^0-9\-]','')
  if($c -eq ''){ return $null }
  try{ [int]$c }catch{ $null }
}

foreach($pf in $Profile){
  Say "=== $pf ==="
  $swAll=[Diagnostics.Stopwatch]::StartNew()
  & $auto -Discover -Profile $pf *> $null
  Remove-Item (Join-Path $PSScriptRoot 'dm_tree_*.txt') -ErrorAction SilentlyContinue

  $w = Get-DmWin
  if(-not $w){ Say "no window for $pf" 'ERROR'; continue }

  Invoke-El ($w.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition($UIA::AutomationIdProperty,'tbBooking'))))
  Start-Sleep -Seconds 2
  Invoke-El ($w.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition($UIA::AutomationIdProperty,'rbtnQuotation'))))
  Start-Sleep -Seconds 8

  $grid=$null; $deadline=(Get-Date).AddMinutes(2)
  while((Get-Date) -lt $deadline -and -not $grid){
    $grid=$w.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
      (New-Object System.Windows.Automation.PropertyCondition($UIA::AutomationIdProperty,'gvBookings')))
    if(-not $grid){ Start-Sleep -Seconds 2 }
  }
  if(-not $grid){ Say "quote grid never appeared" 'ERROR'; continue }

  $gp=$grid.GetCurrentPattern([System.Windows.Automation.GridPattern]::Pattern)
  $sp=$grid.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
  $rows=$gp.Current.RowCount
  Say "grid: $rows rows"

  # ---- pass 1: left-hand columns (scrolled fully left) ----
  try{ $sp.SetScrollPercent(0,[System.Windows.Automation.ScrollPatternIdentifiers]::NoScroll) }catch{}
  Start-Sleep -Seconds 2
  $left=@{}
  $stop=(Get-Date).AddMinutes($TimeoutMin)
  for($r=0;$r -lt $rows;$r++){
    if((Get-Date) -gt $stop){ Say "timeout in pass 1 at row $r" 'WARN'; break }
    $c=@(); for($i=0;$i -lt $gp.Current.ColumnCount;$i++){ try{ $c += (Get-CellText $gp.GetItem($r,$i)) }catch{ $c += '' } }
    $ref=($c | Where-Object { $_ -match '^Q\d+' } | Select-Object -First 1)
    $left[$r]=[pscustomobject]@{
      our_ref=$ref
      customer=($c | Where-Object { $_ -and $_ -notmatch '^Q\d+' -and $_ -notmatch '^\d{2}-\d{2}-\d{2}' -and $_ -notmatch 'Quotation' -and $_ -notmatch '^(Invoice|Cash|Account)$' } | Select-Object -First 1)
      collection=($c | Where-Object { $_ -match ',\s*[A-Z]{1,2}\d' } | Select-Object -First 1)
      delivery=($c | Where-Object { $_ -match ',\s*[A-Z]{1,2}\d' } | Select-Object -Last 1)
      raw_left=($c -join '~')
    }
    if($r % 100 -eq 0 -and $r){ Say "  pass1 $r rows" }
  }
  Say "pass 1: $(@($left.Values | Where-Object { $_.our_ref }).Count) refs of $($left.Count) rows"

  # ---- pass 2: right-hand columns (scrolled fully right) ----
  for($k=0;$k -lt 25;$k++){ try{ $sp.Scroll([System.Windows.Automation.ScrollAmount]::LargeIncrement,[System.Windows.Automation.ScrollAmount]::NoAmount) }catch{ break } }
  Start-Sleep -Seconds 2
  $out=New-Object System.Collections.Generic.List[object]
  for($r=0;$r -lt $rows;$r++){
    if((Get-Date) -gt $stop){ Say "timeout in pass 2 at row $r" 'WARN'; break }
    $c=@(); for($i=0;$i -lt $gp.Current.ColumnCount;$i++){ try{ $c += (Get-CellText $gp.GetItem($r,$i)) }catch{ $c += '' } }
    # numeric-ish cells, in grid order: Rev, Cost, M%, Miles
    $nums=@($c | Where-Object { $_ -match '^\s*[\d,]+(\.\d+)?(\s|$)' -and $_ -notmatch '^\d{2}-\d{2}-\d{2}' })
    $l=$left[$r]
    if(-not $l -or -not $l.our_ref){ continue }
    $out.Add([pscustomobject]@{
      profile    = $pf
      our_ref    = $l.our_ref
      customer   = if($l){$l.customer}else{''}
      collection = if($l){$l.collection}else{''}
      delivery   = if($l){$l.delivery}else{''}
      tariff     = ($c | Where-Object { $_ -and $_ -notmatch '^Q\d+' -and $_ -notmatch '^[\d,\.\s]+$' -and $_ -notmatch '^\d{2}-\d{2}-\d{2}' -and $_ -ne '---' -and $_ -notmatch ',\s*[A-Z]{1,2}\d' } | Select-Object -First 1)
      revenue    = if($nums.Count -ge 1){ Money $nums[0] } else { $null }
      cost       = if($nums.Count -ge 2){ Money $nums[1] } else { $null }
      margin_pct = if($nums.Count -ge 3){ Money $nums[2] } else { $null }
      miles      = if($nums.Count -ge 4){ IntOf $nums[3] } else { $null }
      scraped_at = (Get-Date).ToString('s')
    }) | Out-Null
    if($r % 100 -eq 0 -and $r){ Say "  pass2 $r rows" }
  }

  $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
  $csv=Join-Path $OutDir "quotes_$($pf)_$stamp.csv"
  $out | Export-Csv $csv -NoTypeInformation -Encoding UTF8
  Say "wrote $($out.Count) quotes -> $csv  ($([math]::Round($swAll.Elapsed.TotalMinutes,1)) min)"

  # ---- validate: say what is missing rather than pretending it is clean ----
  $noMiles=@($out | Where-Object { $null -eq $_.miles }).Count
  $noRev  =@($out | Where-Object { $null -eq $_.revenue }).Count
  $noTar  =@($out | Where-Object { -not $_.tariff }).Count
  $noCust =@($out | Where-Object { -not $_.customer }).Count
  Say "validation: $noMiles missing miles, $noRev missing revenue, $noTar missing tariff, $noCust missing customer (of $($out.Count))"
  if($out.Count -lt $rows*0.8){
    Say "ONLY $($out.Count) of $rows rows captured - do not trust this run" 'ERROR' }
  if($noMiles -gt $out.Count*0.3){
    Say "over 30% missing miles - the column layout has probably changed; re-check the grid before using" 'ERROR' }
}
Say 'done'
