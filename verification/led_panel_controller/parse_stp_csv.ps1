$path = Join-Path $PSScriptRoot 'output_files\led_panel_controller.csv'
$lines = Get-Content $path
$hdrLine = ($lines | Select-String '^Data:').LineNumber
$cols = ($lines[$hdrLine] -replace ',\s*$','').Split(',') | ForEach-Object { $_.Trim() }
function Col([string]$name) { [array]::IndexOf($cols, $name) }

$idx = @{
  bist_done = (Col 'bist_done')
  fail = (Col 'fail_latched')
  cmd_phase = (Col 'command_phase')
  idle = (Col 'state.ST_IDLE')
  wait = (Col 'state.ST_WAIT_DISPLAY')
  wi = (Col 'write_index[31..0]')
  wc = (Col 'wait_counter[31..0]')
  clk = (Col 'clk_pulse_count[31..0]')
  latch = (Col 'latch_count[31..0]')
  gpi = (Col 'group_pixel_index[31..0]')
  bcm = (Col 'expected_bcm[3..0]')
  addr = (Col 'expected_panel_addr[3..0]')
  top = (Col 'current_expected_top_data[11..0]')
  bot = (Col 'current_expected_bottom_data[11..0]')
  r1 = (Col 'hub75_r1[0..0]')
  g1 = (Col 'hub75_g1[0..0]')
  b1 = (Col 'hub75_b1[0..0]')
  oe = (Col 'oe_seen')
  clk_rise = (Col 'panel_clk_rise')
  lat_rise = (Col 'panel_lat_rise')
  sdram_init = (Col 'sdram_init_countdown[23..0]')
}

$rows = New-Object System.Collections.Generic.List[object]
for ($n = $hdrLine; $n -lt $lines.Count; $n++) {
  $line = $lines[$n].TrimEnd(',')
  if ($line -eq '') { continue }
  $p = $line.Split(',')
  if ($p[0] -match '^\d+$') { $rows.Add([pscustomobject]@{ t = [int]$p[0]; p = $p }) }
}

Write-Host "Samples: $($rows.Count)"
$prev = $null
foreach ($r in $rows) {
  $v = $r.p[$idx.fail]
  if ($v -ne $prev) {
    Write-Host ("fail_latched {0} -> {1} at {2}ns idle={3} wait={4} wi={5} clk={6} latch={7} bcm={8} addr={9}" -f $prev,$v,$r.t,$r.p[$idx.idle],$r.p[$idx.wait],$r.p[$idx.wi],$r.p[$idx.clk],$r.p[$idx.latch],$r.p[$idx.bcm],$r.p[$idx.addr])
    $prev = $v
  }
}

$first = $rows[0]; $last = $rows[-1]
Write-Host ("First @ {0}ns: bist_done={1} fail={2} idle={3} wait={4} wi={5} sdram_init={6}" -f $first.t,$first.p[$idx.bist_done],$first.p[$idx.fail],$first.p[$idx.idle],$first.p[$idx.wait],$first.p[$idx.wi],$first.p[$idx.sdram_init])
Write-Host ("Last  @ {0}ns: bist_done={1} fail={2} idle={3} wait={4} wi={5} clk={6}/4096 latch={7}/64 wc={8} oe={9}" -f $last.t,$last.p[$idx.bist_done],$last.p[$idx.fail],$last.p[$idx.idle],$last.p[$idx.wait],$last.p[$idx.wi],$last.p[$idx.clk],$last.p[$idx.latch],$last.p[$idx.wc],$last.p[$idx.oe])

foreach ($r in $rows) {
  if ($r.p[$idx.wait] -eq '1' -and $r.p[$idx.idle] -eq '0') {
    Write-Host ("Enter ST_WAIT_DISPLAY @ {0}ns wi={1} clk={2} latch={3}" -f $r.t,$r.p[$idx.wi],$r.p[$idx.clk],$r.p[$idx.latch])
    break
  }
}

foreach ($r in $rows) {
  if ($r.p[$idx.clk_rise] -eq '1' -and $r.p[$idx.wait] -eq '1') {
    Write-Host ("First panel_clk_rise in wait @ {0}ns gpi={1} bcm={2} addr={3} top={4} bot={5} r1/g1/b1={6}/{7}/{8} fail={9}" -f $r.t,$r.p[$idx.gpi],$r.p[$idx.bcm],$r.p[$idx.addr],$r.p[$idx.top],$r.p[$idx.bot],$r.p[$idx.r1],$r.p[$idx.g1],$r.p[$idx.b1],$r.p[$idx.fail])
    break
  }
}

foreach ($r in $rows) {
  if ($r.p[$idx.bist_done] -eq '1' -and $r.p[$idx.bist_done] -ne $null) {
    Write-Host ("bist_done=1 @ {0}ns fail={1} idle={2} wait={3} clk={4} latch={5} wc={6}" -f $r.t,$r.p[$idx.fail],$r.p[$idx.idle],$r.p[$idx.wait],$r.p[$idx.clk],$r.p[$idx.latch],$r.p[$idx.wc])
    break
  }
}

# max clk/latch during capture
$maxClk = 0; $maxLatch = 0
foreach ($r in $rows) {
  $c = [Convert]::ToInt32($r.p[$idx.clk], 16)
  $l = [Convert]::ToInt32($r.p[$idx.latch], 16)
  if ($c -gt $maxClk) { $maxClk = $c }
  if ($l -gt $maxLatch) { $maxLatch = $l }
}
Write-Host "Max clk_pulse_count=$maxClk (expect 4096), max latch_count=$maxLatch (expect 64)"
