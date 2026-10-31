# Release audit, administrator part (security gate S7 + "what it changes"): run ONCE in an elevated PowerShell.
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\audit_admin_run.ps1
# 1. Reads the NTFS change journal (USN) position, waits through a CONTROL window with no check running, then runs
#    the LUMINOL check (same length window) and reads the journal again. The two windows are compared afterwards:
#    a change in the check window that is not background noise and not the report itself would contradict
#    docs/public/WHAT-IT-CHANGES.md. (Last-access updates are not written to the change journal.)
# 2. Polls the check process's TCP connections and UDP endpoints every 100 ms: a check without -Timestamp must open none.
# Writes everything to dist\audit\admin-run\. Changes no setting. Reads the signed-in profile like a normal check.
$ErrorActionPreference = 'Stop'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Host 'Run this in an elevated PowerShell (Run as administrator).' -ForegroundColor Red; exit 1 }
$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root 'dist\audit\admin-run'
if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Recurse -Force }
New-Item -ItemType Directory -Path $out | Out-Null
$fsutil = Join-Path $env:SystemRoot 'System32\fsutil.exe'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
function Get-NextUsn {
  $line = (& $fsutil usn queryjournal C: | Where-Object { $_ -match 'Next Usn' }) -replace '.*:\s*', ''
  return [Convert]::ToInt64($line.Trim(), 16)
}
$controlSeconds = 30
Write-Host "Control window: $controlSeconds s with no check running. Please do not use the computer." -ForegroundColor Cyan
$usnControl = Get-NextUsn
$t0 = Get-Date
Start-Sleep -Seconds $controlSeconds
$usnCheck = Get-NextUsn
Write-Host 'Check window: running LUMINOL (no timestamp) and watching its network use...' -ForegroundColor Cyan
$t1 = Get-Date
$check = Join-Path $root 'src\Luminol-Check.ps1'
$p = Start-Process -FilePath $powershell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$check`"", '-OutDir', "`"$out\report`"", '-NoOpen') -PassThru -WindowStyle Hidden
$net = New-Object System.Collections.ArrayList
$polls = 0
while (-not $p.HasExited) {
  $polls++
  foreach ($c in @(Get-NetTCPConnection -OwningProcess $p.Id -ErrorAction SilentlyContinue)) { [void]$net.Add("TCP $($c.LocalAddress):$($c.LocalPort) -> $($c.RemoteAddress):$($c.RemotePort) $($c.State)") }
  foreach ($u in @(Get-NetUDPEndpoint -OwningProcess $p.Id -ErrorAction SilentlyContinue)) { [void]$net.Add("UDP $($u.LocalAddress):$($u.LocalPort)") }
  Start-Sleep -Milliseconds 100
}
$checkSeconds = ((Get-Date) - $t1).TotalSeconds
# Pad the check window to the control length so both windows see the same amount of background activity.
if ($checkSeconds -lt $controlSeconds) { Start-Sleep -Seconds ([Math]::Ceiling($controlSeconds - $checkSeconds)) }
$usnEnd = Get-NextUsn
$csv = Join-Path $out 'usn.csv'
$raw = @(& $fsutil usn readjournal C: startusn=$usnControl csv)
$raw | Out-File -LiteralPath $csv -Encoding utf8
# Resolve parent folders of every record so the comparison can use full paths (file IDs need admin to resolve).
# The CSV may be preceded by non-CSV lines; start at the header row.
$headerAt = 0
for ($i = 0; $i -lt $raw.Count; $i++) { if ($raw[$i] -match '^\s*"?Usn"?\s*,') { $headerAt = $i; break } }
$rows = @($raw[$headerAt..($raw.Count - 1)] | ConvertFrom-Csv)
$parentColumn = @($rows | Select-Object -First 1 | ForEach-Object { $_.PSObject.Properties.Name } | Where-Object { $_ -match '^Parent' })[0]
$parents = @{}
foreach ($r in $rows) {
  $id = if ($parentColumn) { $r.$parentColumn } else { $null }
  # fsutil prints IDs without the 0x prefix that queryFileNameById requires (29 Oct run: every lookup failed).
  if ($id -and $id -notmatch '^0x') { $id = '0x' + $id }
  if ($id -and -not $parents.ContainsKey($id) -and $parents.Count -lt 5000) {
    $answer = @(& $fsutil file queryFileNameById C:\ $id 2>$null) -join ' '
    $parents[$id] = ($answer -replace '^.*?\\\\\?\\', '').Trim()
  }
}
$parents.GetEnumerator() | ForEach-Object { [pscustomobject]@{ id = $_.Key; path = $_.Value } } | Export-Csv -LiteralPath (Join-Path $out 'parents.csv') -NoTypeInformation -Encoding utf8
[ordered]@{
  windows_build = [Environment]::OSVersion.Version.ToString()
  control = @{ start_usn = $usnControl; end_usn = $usnCheck; started = $t0.ToUniversalTime().ToString('o'); seconds = $controlSeconds }
  check = @{ start_usn = $usnCheck; end_usn = $usnEnd; started = $t1.ToUniversalTime().ToString('o'); check_seconds = [Math]::Round($checkSeconds, 1); exit_code = $p.ExitCode }
  network = @{ polls = $polls; observations = @($net | Sort-Object -Unique) }
  usn_records_total = $rows.Count
} | ConvertTo-Json -Depth 5 | Out-File -LiteralPath (Join-Path $out 'admin-run.json') -Encoding utf8
Write-Host "Done. Check exit code $($p.ExitCode); network observations: $(@($net | Sort-Object -Unique).Count); journal records: $($rows.Count)." -ForegroundColor Green
Write-Host "Results in $out" -ForegroundColor Green
