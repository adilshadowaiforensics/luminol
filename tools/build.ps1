# Builds dist\LUMINOL-Check-<version>\ and the .zip from committed source. Run from the repo root:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\build.ps1
[CmdletBinding(PositionalBinding = $false)]
param([switch]$AllowDirty)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$dirty = @(& git -C $root status --porcelain -- src)
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect Git source status.' }
if ($dirty.Count -and -not $AllowDirty) { throw 'src/ has uncommitted changes. Commit them first, or use -AllowDirty for a clearly marked development ZIP.' }
$buildRoot = $root
$staging = $null
if (-not $AllowDirty) {
  $staging = Join-Path $root ('.build-stage-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $staging | Out-Null
  $archive = Join-Path $staging 'source.zip'
  & git -C $root archive --format=zip --output=$archive HEAD
  if ($LASTEXITCODE -ne 0) { throw 'git archive failed.' }
  $buildRoot = Join-Path $staging 'source'
  Expand-Archive -LiteralPath $archive -DestinationPath $buildRoot
}
# Check every text source copied into the ZIP or public export. Build the marker from
# characters so this guard does not flag its own source in the public repository.
$marker = [string][char]123 + [string][char]123
$publicInputs = @('README.md', 'src', 'docs/public', 'tools/build.ps1', 'docs/sample-report.json',
  'tools/measure_changes.py', 'docs/testing/l2b-measurement-2026-10-23.json',
  'docs/testing/l4-measurement-2026-10-24.json',
  'tests/test_check.py', 'tests/test_app.py', 'tests/test_window_live.py', 'tests/test_seal.py',
  'tests/test_no_trace.py', 'LICENSE')
$placeholderHits = @()
foreach ($relative in $publicInputs) {
  $path = Join-Path $buildRoot $relative
  if (-not (Test-Path -LiteralPath $path)) { continue }
  $filesToCheck = if ((Get-Item -LiteralPath $path).PSIsContainer) { @(Get-ChildItem -LiteralPath $path -File -Recurse) } else { @(Get-Item -LiteralPath $path) }
  foreach ($file in $filesToCheck) {
    if ($file.Extension -notin @('.ps1', '.cmd', '.json', '.html', '.md', '.txt', '.py', '.xaml', '')) { continue }
    if ([IO.File]::ReadAllText($file.FullName).Contains($marker)) { $placeholderHits += $relative + ': ' + $file.Name }
  }
}
if ($placeholderHits.Count) {
  $names = ($placeholderHits | Sort-Object -Unique) -join ', '
  if ($AllowDirty) { Write-Warning "Development build contains unresolved placeholders: $names" }
  else {
    if ($staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    throw "Release build refused: unresolved placeholders in $names"
  }
}
$src = Join-Path $buildRoot 'src'
$version = ((Get-Content (Join-Path $src 'Luminol-Check.ps1')) | Select-String "^\`$LuminolVersion = '([^']+)'").Matches[0].Groups[1].Value
$name = "LUMINOL-Check-$version"
if ($AllowDirty) { $name += '-dirty' }
$dist = Join-Path $root 'dist'
$out = Join-Path $dist $name
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
New-Item -ItemType Directory -Path $out -Force | Out-Null
$files = @('LUMINOL.cmd', 'Luminol-App.ps1', 'Luminol-Check.ps1', 'Luminol-Seal.ps1', 'catalog.json', 'report-template.html', 'Run LUMINOL Check.cmd', 'README.txt')
foreach ($f in $files) { Copy-Item (Join-Path $src $f) (Join-Path $out $f) }
# App window: the XAML and its icon only.
New-Item -ItemType Directory -Path (Join-Path $out 'ui') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path (Join-Path $out 'ui') 'assets') -Force | Out-Null
Copy-Item (Join-Path (Join-Path $src 'ui') 'MainWindow.xaml') (Join-Path (Join-Path $out 'ui') 'MainWindow.xaml')
Copy-Item (Join-Path (Join-Path (Join-Path $src 'ui') 'assets') 'luminol.ico') (Join-Path (Join-Path (Join-Path $out 'ui') 'assets') 'luminol.ico')
# Bundled brand fonts (IBM Plex, SIL OFL): without them the window silently falls back to a default font. A window that
# names bundled fonts but a tree that lacks them is a broken release, so refuse instead of shipping it.
$fontSrc = Join-Path (Join-Path (Join-Path $src 'ui') 'assets') 'fonts'
$xamlText = [IO.File]::ReadAllText((Join-Path (Join-Path $src 'ui') 'MainWindow.xaml'))
if ($xamlText.Contains('assets/fonts/')) {
  foreach ($need in @('IBMPlexSans-400.ttf', 'IBMPlexMono-400.ttf', 'OFL.txt')) {
    if (-not (Test-Path -LiteralPath (Join-Path $fontSrc $need))) { throw "MainWindow.xaml uses bundled fonts but src/ui/assets/fonts/$need is missing." }
  }
}
if (Test-Path -LiteralPath $fontSrc) {
  $fontOut = Join-Path (Join-Path (Join-Path $out 'ui') 'assets') 'fonts'
  New-Item -ItemType Directory -Path $fontOut -Force | Out-Null
  Copy-Item (Join-Path $fontSrc '*') $fontOut
}
Copy-Item (Join-Path $buildRoot 'LICENSE') (Join-Path $out 'LICENSE')
# Scripts must be plain ASCII: Windows PowerShell 5.1 reads files without a BOM in the ANSI code page.
foreach ($f in @('Luminol-App.ps1', 'Luminol-Check.ps1', 'Luminol-Seal.ps1')) {
  $bytes = [IO.File]::ReadAllBytes((Join-Path $out $f))
  if (@($bytes | Where-Object { $_ -gt 127 }).Count) { throw "$f contains non-ASCII characters" }
}
# The catalogue must be valid JSON and the template must carry the data placeholder exactly once.
$null = Get-Content (Join-Path $out 'catalog.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$t = Get-Content (Join-Path $out 'report-template.html') -Raw -Encoding UTF8
if (([regex]::Matches($t, [regex]::Escape('/*__LUMINOL_DATA__*/null'))).Count -ne 1) { throw 'report-template.html must contain the data placeholder exactly once' }
function Get-Sha256Hex([string]$path) {
  $hash = [Security.Cryptography.SHA256]::Create()
  $stream = [IO.File]::OpenRead($path)
  try { return -join ($hash.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') }) }
  finally { $stream.Dispose(); $hash.Dispose() }
}
$sep = [IO.Path]::DirectorySeparatorChar
$sums = Get-ChildItem $out -File -Recurse | Sort-Object FullName | ForEach-Object {
  "{0}  {1}" -f (Get-Sha256Hex $_.FullName), $_.FullName.Substring($out.Length + 1).Replace($sep, '/')
}
# LF line endings so `sha256sum -c SHA256SUMS.txt` works on Linux and macOS as well.
[IO.File]::WriteAllText((Join-Path $out 'SHA256SUMS.txt'), (($sums -join "`n") + "`n"))
# Standard zip: entry names use '/' (Compress-Archive in PowerShell 5.1 writes '\', which Windows tolerates but
# other tools and reviewers see as broken names). Top folder = the directory's own name.
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
function New-StandardZip([string]$dir, [string]$zipPath) {
  if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
  $top = Split-Path $dir -Leaf
  $fixedTime = New-Object DateTimeOffset(2026, 10, 20, 0, 0, 0, [TimeSpan]::Zero)
  $fs = [IO.File]::Open($zipPath, [IO.FileMode]::CreateNew)
  $za = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
  try {
    Get-ChildItem $dir -File -Recurse | Sort-Object FullName | ForEach-Object {
      $entry = $top + '/' + $_.FullName.Substring($dir.Length + 1).Replace('\', '/')
      # Fixed entry time, set before writing (.NET Framework forbids it after): the same files always give the same zip.
      $e = $za.CreateEntry($entry, [IO.Compression.CompressionLevel]::Optimal)
      $e.LastWriteTime = $fixedTime
      $w = $e.Open()
      try { $bytes = [IO.File]::ReadAllBytes($_.FullName); $w.Write($bytes, 0, $bytes.Length) } finally { $w.Dispose() }
    }
  } finally { $za.Dispose(); $fs.Dispose() }
  $check = [IO.Compression.ZipFile]::OpenRead($zipPath)
  try {
    if (@($check.Entries | Where-Object { $_.FullName.Contains('\') }).Count) { throw "$zipPath has backslash entry names" }
    $want = @(Get-ChildItem $dir -File -Recurse).Count
    if ($check.Entries.Count -ne $want) { throw "$zipPath has $($check.Entries.Count) entries, expected $want" }
  } finally { $check.Dispose() }
}

$zip = Join-Path $dist "$name.zip"
New-StandardZip $out $zip
[IO.File]::WriteAllText((Join-Path $dist "$name.zip.sha256"), ("{0}  {1}`n" -f (Get-Sha256Hex $zip), (Split-Path $zip -Leaf)))
Write-Host "Built $zip"

# Test kit: proves LUMINOL works on another Windows PC using a fake profile (no real data touched).
$kitName = "LUMINOL-TestKit-$version"
if ($AllowDirty) { $kitName += '-dirty' }
$kitDir = Join-Path $dist $kitName
if (Test-Path $kitDir) { Remove-Item $kitDir -Recurse -Force }
New-Item -ItemType Directory -Path $kitDir -Force | Out-Null
Copy-Item (Join-Path (Join-Path $buildRoot 'tools') 'testkit\*') $kitDir
Copy-Item $out (Join-Path $kitDir $name) -Recurse
$kitZip = Join-Path $dist "$kitName.zip"
New-StandardZip $kitDir $kitZip
Write-Host "Built $kitZip"
if ($staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
