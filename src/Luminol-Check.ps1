<#
.SYNOPSIS
  LUMINOL Check - what AI evidence still exists on this computer, and how long before it is gone.

.DESCRIPTION
  Free tool by Shadow AI Forensics. Runs as the current Windows user. No administrator rights, no internet, no
  installation. It writes one HTML report (and the same data as JSON) to Documents\LUMINOL and opens it.

  What it reads:
    - names, sizes and dates of files in known AI app and browser folders;
    - whether AI site names (for example "chatgpt.com") appear inside browser history and the Windows
      notification database, as a yes/no per site;
    - the "downloaded from" mark Windows stores with downloaded files (site name only).
  It does not read conversation text. LUMINOL does not change the contents, size, dates or attributes of any file it
  checks - except that Windows may update the last-access time of files and folders it reads.

.PARAMETER ProfileRoot
  User profile to check. Default: the current user's profile.
.PARAMETER OutDir
  Where the report is written. Default: Documents\LUMINOL.
.PARAMETER NoOpen
  Do not open the report when done.
.PARAMETER Timestamp
  Opt-in sealed snapshot: after writing the report, send ONLY its SHA-256 fingerprint (mixed with a random number)
  to public OpenTimestamps calendars and save the proof files next to the report. Without this switch, nothing
  leaves the computer.
.PARAMETER ProgressSink
  For the LUMINOL app window: a synchronized hashtable that receives the current step, a percentage and the
  report paths. Changes nothing about what is checked.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
  [string]$ProfileRoot = $env:USERPROFILE,
  [string]$OutDir = '',
  [switch]$NoOpen,
  [string]$Now = '',
  [string]$TimeZoneForTest = '',
  [hashtable]$ProgressSink = $null,
  [switch]$Timestamp,
  [string[]]$TimestampCalendars = @(),
  [string[]]$BrowserProcessesForTest = $null,
  [switch]$SampleData,
  [string]$LastAccessRawForTest = ''
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
# Locked-down company PCs (AppLocker/WDAC) run unapproved scripts in Constrained Language Mode, where LUMINOL cannot
# work. Say so plainly instead of failing on the first line (stress test 2026-10-18).
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
  Write-Host 'LUMINOL cannot run on this computer: its security settings only let approved scripts run (PowerShell "Constrained Language Mode", usually set by the IT department). Nothing was checked. Ask IT to run LUMINOL, or to allow it.' -ForegroundColor Red
  exit 3
}
# Dates in the report are always Gregorian and in English, whatever the Windows language or calendar: on Arabic
# (Saudi) or Thai Windows the default calendar would write the year as 1448 or 2569 (stress test 2026-10-18).
$Inv = [Globalization.CultureInfo]::InvariantCulture
$reportTimeZone = if ($TimeZoneForTest) { [TimeZoneInfo]::FindSystemTimeZoneById($TimeZoneForTest) } else { [TimeZoneInfo]::Local }
function Local-Date($dt) { return [TimeZoneInfo]::ConvertTimeFromUtc($dt.ToUniversalTime(), $reportTimeZone) }
$LuminolVersion = '0.1.1'
$started = Get-Date
$nowUtc = if ($Now) { [datetime]::Parse($Now).ToUniversalTime() } else { (Get-Date).ToUniversalTime() }
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$problems = New-Object System.Collections.ArrayList
$partialChecks = New-Object System.Collections.ArrayList
$partialPatterns = @{}
function Add-Partial([string]$message) {
  if (-not $partialChecks.Contains($message)) {
    [void]$partialChecks.Add($message)
    [void]$problems.Add($message)
  }
}
function Set-Progress([string]$step, [double]$percent) {
  if ($null -ne $ProgressSink) { $ProgressSink['step'] = $step; $ProgressSink['percent'] = [Math]::Round($percent) }
}
Set-Progress 'Starting' 1

# Process names are sufficient for this warning; command lines and window titles are never collected.
$browserNames = [ordered]@{ chrome = 'Chrome'; msedge = 'Edge'; firefox = 'Firefox'; brave = 'Brave'; opera = 'Opera'; vivaldi = 'Vivaldi'; arc = 'Arc' }
$runningNames = if ($null -ne $BrowserProcessesForTest) { @($BrowserProcessesForTest | ForEach-Object { $_ -split ',' }) } else { @(Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessName }) }
$browsersOpen = @($browserNames.Keys | Where-Object { $runningNames -contains $_ } | ForEach-Object { $browserNames[$_] })
foreach ($browser in $browsersOpen) {
  Write-Host "$browser is open, so its history is locked and may be reported as unreadable. Close it for a complete check, or continue." -ForegroundColor Yellow
}

$outDirGiven = [bool]$OutDir
if (-not $OutDir) { $OutDir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'LUMINOL' }
function Test-Writable([string]$dir) {
  try {
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $probe = Join-Path $dir ('.luminol-write-test-' + [guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($probe, ''); Remove-Item -LiteralPath $probe -Force
    return $true
  } catch { return $false }
}
$catalogPath = Join-Path $here 'catalog.json'
$templatePath = Join-Path $here 'report-template.html'
foreach ($p in @($catalogPath, $templatePath)) {
  if (-not (Test-Path -LiteralPath $p)) { Write-Host "LUMINOL: missing $p. Keep all files from the download together." -ForegroundColor Red; if ($null -ne $ProgressSink) { $ProgressSink['error'] = "Missing file: $(Split-Path -Leaf $p). Keep all files from the download together." }; exit 2 }
}
$catalog = [IO.File]::ReadAllText($catalogPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
$template = [IO.File]::ReadAllText($templatePath, [Text.Encoding]::UTF8)

# ----------------------------------------------------------------------------------------------- paths
$isCurrentUser = ($ProfileRoot.TrimEnd('\') -eq $env:USERPROFILE.TrimEnd('\'))
$nonDefaultNames = New-Object System.Collections.ArrayList
foreach ($name in @('Now', 'TimeZoneForTest', 'BrowserProcessesForTest', 'LastAccessRawForTest', 'TimestampCalendars', 'SampleData')) {
  if ($PSBoundParameters.ContainsKey($name)) { [void]$nonDefaultNames.Add($name) }
}
if (-not $isCurrentUser) { [void]$nonDefaultNames.Add('ProfileRoot') }
$roots = @{
  'USERPROFILE'  = $ProfileRoot.TrimEnd('\')
  'APPDATA'      = $(if ($isCurrentUser -and $env:APPDATA) { $env:APPDATA } else { Join-Path $ProfileRoot 'AppData\Roaming' })
  'LOCALAPPDATA' = $(if ($isCurrentUser -and $env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $ProfileRoot 'AppData\Local' })
}

function Expand-Token([string]$path) {
  foreach ($k in $roots.Keys) { $path = $path.Replace("%$k%", $roots[$k]) }
  return $path
}

# Paths in the report never show the user name: the profile folder is shown as %USERPROFILE%.
function Hide-Profile([string]$path) {
  foreach ($k in @('LOCALAPPDATA', 'APPDATA', 'USERPROFILE')) {
    $r = $roots[$k]
    # Exception messages can quote a full path in the middle of a sentence.
    $path = [regex]::Replace($path, [regex]::Escape($r), "%$k%", [Text.RegularExpressions.RegexOptions]::IgnoreCase)
  }
  return $path
}

function Iso($dt) { if ($null -eq $dt) { return $null } return $dt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', $Inv) }

# Files matching a catalogue pattern. Each wildcard segment is matched in its own directory;
# "**" spans any number of directories. Reparse points are not traversed.
function Get-ReparseLocation([string]$path) {
  $full = [IO.Path]::GetFullPath($path)
  $profileFull = [IO.Path]::GetFullPath($ProfileRoot).TrimEnd('\')
  # A profile root may itself be a junction. Trust it and inspect only its children.
  $inside = $full.StartsWith($profileFull + '\', [StringComparison]::OrdinalIgnoreCase)
  $cursor = if ($inside) { $profileFull } else { [IO.Path]::GetPathRoot($full) }
  $relative = $full.Substring($cursor.Length).TrimStart('\')
  foreach ($segment in @($relative -split '\\')) {
    if (-not $segment) { continue }
    $cursor = Join-Path $cursor $segment
    if (-not (Test-Path -LiteralPath $cursor)) { break }
    $entry = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
    if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $cursor }
  }
  return ''
}
function Mark-LinkedPattern([string]$pattern, [string]$location) {
  $partialPatterns[$pattern] = 'linked'
  Add-Partial "$(Hide-Profile $location): This folder is a link to another location. LUMINOL does not follow links, so it was not checked."
}
function Get-PatternFiles([string]$pattern, [int]$cap = 20000) {
  $full = Expand-Token $pattern
  if ($full -notmatch '[\*\?]') {
    $link = Get-ReparseLocation $full
    if ($link) { Mark-LinkedPattern $pattern $link; return @() }
    if (Test-Path -LiteralPath $full -PathType Leaf) {
      return @(Get-Item -LiteralPath $full -Force)
    }
    return @()
  }
  $parts = $full -split '\\'
  $baseParts = @()
  foreach ($seg in $parts) { if ($seg -match '[\*\?]') { break }; $baseParts += $seg }
  $base = $baseParts -join '\'
  $link = Get-ReparseLocation $base
  if ($link) { Mark-LinkedPattern $pattern $link; return @() }
  if (-not (Test-Path -LiteralPath $base -PathType Container)) { return @() }
  $remaining = @($parts[$baseParts.Count..($parts.Count - 1)])
  $hits = New-Object System.Collections.ArrayList
  $linkedSkipped = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  $pending = New-Object System.Collections.Stack
  $pending.Push(@{ dir = $base; index = 0 })
  try {
    while ($pending.Count -and $hits.Count -le $cap) {
      $state = $pending.Pop()
      $dir = [string]$state.dir
      $index = [int]$state.index
      $segment = [string]$remaining[$index]
      if ($segment -eq '**') {
        $pending.Push(@{ dir = $dir; index = $index + 1 })
        foreach ($child in @(Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction Stop)) {
          if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
            $pending.Push(@{ dir = $child.FullName; index = $index })
          } else {
            [void]$linkedSkipped.Add($child.FullName)
          }
        }
      } elseif ($index -eq $remaining.Count - 1) {
        foreach ($file in @(Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction Stop)) {
          if ($file.Name -like $segment -and ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
            [void]$hits.Add($file)
            if ($hits.Count -gt $cap) { break }
          }
        }
      } else {
        foreach ($child in @(Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction Stop)) {
          if ($child.Name -like $segment -and ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
            $pending.Push(@{ dir = $child.FullName; index = $index + 1 })
          } elseif ($child.Name -like $segment) {
            Mark-LinkedPattern $pattern $child.FullName
          }
        }
      }
    }
    if ($linkedSkipped.Count) {
      if ([string]$partialPatterns[$pattern] -ne 'linked') { $partialPatterns[$pattern] = $true }
      Add-Partial "$($linkedSkipped.Count) linked folder(s) under $(Hide-Profile $base) were not followed."
    }
    if ($hits.Count -gt $cap) {
      if ([string]$partialPatterns[$pattern] -ne 'linked') { $partialPatterns[$pattern] = $true }
      Add-Partial "File scan of $(Hide-Profile $base) stopped after $cap matching files. Its count and date range are partial; more files exist."
      return @($hits.GetRange(0, $cap).ToArray())
    }
    return @($hits.ToArray())
  } catch {
    if ([string]$partialPatterns[$pattern] -ne 'linked') { $partialPatterns[$pattern] = $true }
    Add-Partial "Could not fully list $(Hide-Profile $base): $(Hide-Profile $_.Exception.Message)"
    return @($hits.ToArray())
  }
}

function Summarize-Files($files) {
  $files = @($files)
  if ($files.Count -eq 0) { return $null }
  $newest = ($files | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).LastWriteTimeUtc
  $oldest = ($files | Sort-Object LastWriteTimeUtc | Select-Object -First 1).LastWriteTimeUtc
  $bytes = ($files | Measure-Object -Property Length -Sum).Sum
  return [ordered]@{ files = $files.Count; bytes = [long]$bytes; newest = (Iso $newest); oldest = (Iso $oldest) }
}

# Yes/no search for short ASCII names inside a file (e.g. "chatgpt.com"). Opens read-only and shares the file with
# the app that owns it. Returns $null when the file cannot be read (typically locked by a running browser).
function Find-Needles([string]$path, [string[]]$needles, [long]$maxBytes = 800MB) {
  $found = New-Object 'System.Collections.Generic.HashSet[string]'
  # Lower-case the text once per chunk and search ordinally: same result as a case-insensitive search for these ASCII
  # names, about 70 times faster (a 1 GB browser history took 591 s, now about 8 s - stress test 2026-10-18).
  $lower = @{}; foreach ($x in $needles) { $lower[$x] = $x.ToLowerInvariant() }
  try {
    $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
  } catch {
    return $null
  }
  try {
    $latin1 = [Text.Encoding]::GetEncoding(28591)
    $buf = New-Object byte[] (4MB)
    $longest = ($needles | Measure-Object -Property Length -Maximum).Maximum
    $tail = ''
    $total = 0L
    while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
      $total += $n
      $chunk = ($tail + $latin1.GetString($buf, 0, $n)).ToLowerInvariant()
      foreach ($needle in $needles) {
        if (-not $found.Contains($needle) -and $chunk.IndexOf($lower[$needle], [StringComparison]::Ordinal) -ge 0) { [void]$found.Add($needle) }
      }
      if ($found.Count -eq $needles.Count) { break }
      if ($total -ge $maxBytes) {
        if ($fs.Position -lt $fs.Length) {
          $partialReads[$path] = $true
          Add-Partial "Site-name search of $(Hide-Profile $path) stopped after $total of $($fs.Length) bytes. Any match beyond that point is unknown."
        }
        break
      }
      $keep = [Math]::Min($chunk.Length, $longest)
      $tail = $chunk.Substring($chunk.Length - $keep)
    }
  } finally {
    $fs.Dispose()
  }
  return ,([string[]]@($found))
}

# ----------------------------------------------------------------------------------------------- services
$domainToService = @{}
$serviceNames = @{}
foreach ($s in $catalog.services) {
  $serviceNames[$s.id] = $s.name
  foreach ($d in $s.domains) { $domainToService[$d] = $s.id }
}
$allDomains = [string[]]@($domainToService.Keys)
$partialReads = @{}
$servicesSeen = @{}   # service id -> list of where it was seen
function Note-Service([string]$service, [string]$where) {
  if (-not $service -or $service -eq '*') { return }
  if (-not $servicesSeen.ContainsKey($service)) { $servicesSeen[$service] = New-Object System.Collections.ArrayList }
  if (-not $servicesSeen[$service].Contains($where)) { [void]$servicesSeen[$service].Add($where) }
}

# ----------------------------------------------------------------------------------------------- browsers
$chromiumRoots = [ordered]@{
  'Chrome'  = '%LOCALAPPDATA%\Google\Chrome\User Data'
  'Edge'    = '%LOCALAPPDATA%\Microsoft\Edge\User Data'
  'Brave'   = '%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data'
  'Vivaldi' = '%LOCALAPPDATA%\Vivaldi\User Data'
  'Opera'   = '%APPDATA%\Opera Software'
}
function Get-ChromiumProfiles {
  $out = New-Object System.Collections.ArrayList
  foreach ($browser in $chromiumRoots.Keys) {
    $root = Expand-Token $chromiumRoots[$browser]
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
    $dirs = @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)
    if ($browser -eq 'Opera') { $dirs = @($dirs | Where-Object { $_.Name -like 'Opera*' }) }
    foreach ($d in $dirs) {
      $hist = Join-Path $d.FullName 'History'
      if (Test-Path -LiteralPath $hist -PathType Leaf) { [void]$out.Add([ordered]@{ browser = $browser; profile = $d.Name; dir = $d.FullName; history = $hist; engine = 'chromium' }) }
    }
  }
  $ff = Expand-Token '%APPDATA%\Mozilla\Firefox\Profiles'
  if (Test-Path -LiteralPath $ff -PathType Container) {
    foreach ($d in @(Get-ChildItem -LiteralPath $ff -Directory -Force -ErrorAction SilentlyContinue)) {
      $hist = Join-Path $d.FullName 'places.sqlite'
      if (Test-Path -LiteralPath $hist -PathType Leaf) { [void]$out.Add([ordered]@{ browser = 'Firefox'; profile = $d.Name; dir = $d.FullName; history = $hist; engine = 'gecko' }) }
    }
  }
  return $out
}
$browserProfiles = Get-ChromiumProfiles

# ----------------------------------------------------------------------------------------------- detectors
$rawFiles = @{}   # item id -> file list, kept out of the report (used for per-file clock maths only)
function Detect-Files($item) {
  $files = New-Object System.Collections.ArrayList
  $where = New-Object System.Collections.ArrayList
  $seenFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  $foundLocations = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($p in $item.detect.paths) {
    $hits = @(Get-PatternFiles $p)
    if ($item.detect.PSObject.Properties.Name -contains 'exclude_names') {
      $hits = @($hits | Where-Object { $candidate = $_.Name; -not @($item.detect.exclude_names | Where-Object { $candidate -like $_ }).Count })
    }
    if ($hits.Count) {
      [void]$where.Add($p)
      $patternParts = @( (Expand-Token $p) -split '\\' )
      $depth = [Array]::IndexOf($patternParts, '**')
      if ($depth -lt 0) { $depth = $patternParts.Count - 1 }
      foreach ($hit in $hits) {
        if ($seenFiles.Add($hit.FullName)) { [void]$files.Add($hit) }
        $hitParts = @($hit.FullName -split '\\')
        if ($depth -gt 0 -and $hitParts.Count -ge $depth) {
          [void]$foundLocations.Add((Hide-Profile ($hitParts[0..($depth - 1)] -join '\')))
        }
      }
    }
  }
  $rawFiles[$item.id] = @($files)
  $sum = Summarize-Files $files
  $partial = @($item.detect.paths | Where-Object { $partialPatterns.ContainsKey($_) }).Count -gt 0
  $linked = @($item.detect.paths | Where-Object { [string]$partialPatterns[$_] -eq 'linked' }).Count -gt 0
  if ($linked) { return [ordered]@{ present = $null; partial = $true; note = 'This folder is a link to another location. LUMINOL does not follow links, so it was not checked.' } }
  if ($null -eq $sum) {
    if ($partial) { return [ordered]@{ present = $null; partial = $true; note = 'File locations were not fully checked.' } }
    return [ordered]@{ present = $false }
  }
  return [ordered]@{ present = $true; partial = $partial; summary = $sum; locations = @($where); found_locations = @($foundLocations | Sort-Object) }
}

function Detect-BrowserHistory($item) {
  $rows = New-Object System.Collections.ArrayList
  foreach ($bp in $browserProfiles) {
    $found = Find-Needles $bp.history $allDomains
    $wal = @("$($bp.history)-wal", "$($bp.history)-journal") | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
    $walFound = @()
    foreach ($w in $wal) { $r = Find-Needles $w $allDomains; if ($r) { $walFound += $r } }
    $info = Get-Item -LiteralPath $bp.history -Force
    if ($null -eq $found) {
      [void]$rows.Add([ordered]@{ browser = $bp.browser; profile = $bp.profile; readable = $false; partial = $false; services = @(); modified = (Iso $info.LastWriteTimeUtc) })
      [void]$problems.Add("$($bp.browser) ($($bp.profile)) history could not be read, probably because the browser is open. Close it and run LUMINOL again.")
      continue
    }
    $svc = @(@($found) + @($walFound) | ForEach-Object { $domainToService[$_] } | Where-Object { $_ } | Sort-Object -Unique)
    foreach ($s in $svc) { Note-Service $s "$($bp.browser) history" }
    $partial = $partialReads.ContainsKey($bp.history) -or @($wal | Where-Object { $partialReads.ContainsKey($_) }).Count -gt 0
    [void]$rows.Add([ordered]@{ browser = $bp.browser; profile = $bp.profile; engine = $bp.engine; readable = $true; partial = $partial; services = @($svc | ForEach-Object { $serviceNames[$_] }); service_ids = @($svc); modified = (Iso $info.LastWriteTimeUtc) })
  }
  $any = @($rows | Where-Object { $_.services.Count -gt 0 }).Count -gt 0
  $partial = @($rows | Where-Object { $_.partial -eq $true }).Count -gt 0
  if ($partial -and -not $any) { return [ordered]@{ present = $null; profiles = @($rows); note = 'Browser history was partly searched. No matching site was found in the part checked.' } }
  $result = [ordered]@{ present = $any; partial = $partial; profiles = @($rows) }
  if (-not $any) { $result.note = 'No listed AI site in the history files that were read. History the user cleared, and private windows, leave no entry here.' }
  return $result
}

function Detect-SiteStorage($item) {
  $files = New-Object System.Collections.ArrayList
  $where = New-Object System.Collections.ArrayList
  foreach ($bp in $browserProfiles) {
    if ($bp.engine -ne 'chromium') { continue }
    foreach ($origin in $item.detect.origins) {
      $dir = Join-Path $bp.dir "IndexedDB\$origin.indexeddb.leveldb"
      if (Test-Path -LiteralPath $dir -PathType Container) {
        $hits = @(Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue)
        if ($hits.Count) { [void]$files.AddRange($hits); [void]$where.Add("$($bp.browser) ($($bp.profile))") }
      }
    }
  }
  $sum = Summarize-Files $files
  if ($null -eq $sum) { return [ordered]@{ present = $false } }
  return [ordered]@{ present = $true; summary = $sum; locations = @($where) }
}

function Detect-Needles($item) {
  $hitsAll = New-Object System.Collections.ArrayList
  $readable = $false
  $newest = $null
  foreach ($p in $item.detect.paths) {
    $full = Expand-Token $p
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
    $r = Find-Needles $full ([string[]]$item.detect.needles)
    if ($null -eq $r) { continue }
    $readable = $true
    $t = (Get-Item -LiteralPath $full -Force).LastWriteTimeUtc
    if ($null -eq $newest -or $t -gt $newest) { $newest = $t }
    foreach ($x in $r) { if (-not $hitsAll.Contains($x)) { [void]$hitsAll.Add($x) } }
  }
  if (-not $readable) { return [ordered]@{ present = $null; note = 'The notification database could not be read (Windows keeps it in use).' } }
  if ($hitsAll.Count -eq 0 -and @($item.detect.paths | Where-Object { $partialReads.ContainsKey((Expand-Token $_)) }).Count -gt 0) {
    return [ordered]@{ present = $null; note = 'The database was partly searched. No matching name was found in the part checked.'; names = @(); modified = (Iso $newest) }
  }
  return [ordered]@{ present = ($hitsAll.Count -gt 0); names = @($hitsAll); modified = (Iso $newest) }
}

function Detect-Downloads($item) {
  $perService = @{}
  $types = @{}
  $newest = $null
  $checked = 0
  $partial = $false
  foreach ($f in $item.detect.folders) {
    $dir = Expand-Token $f
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
    $files = @(Get-ChildItem -LiteralPath $dir -File -Recurse -Depth $item.detect.max_depth -Force -ErrorAction SilentlyContinue |
      Select-Object -First ($item.detect.max_files + 1))
    if ($files.Count -gt $item.detect.max_files) {
      $partial = $true
      Add-Partial "Download scan of $(Hide-Profile $dir) stopped after $($item.detect.max_files) files. Download counts are partial."
      $files = @($files[0..($item.detect.max_files - 1)])
    }
    foreach ($file in $files) {
      $checked++
      $zone = $null
      # A real Zone.Identifier is a few hundred bytes; skip a planted oversized stream instead of reading it.
      try { if ((Get-Item -LiteralPath $file.FullName -Stream 'Zone.Identifier' -ErrorAction Stop).Length -gt 64KB) { continue }; $zone = Get-Content -LiteralPath $file.FullName -Stream 'Zone.Identifier' -ErrorAction Stop } catch { continue }
      $urls = @($zone | Where-Object { $_ -match '^(HostUrl|ReferrerUrl)=' } | ForEach-Object { ($_ -split '=', 2)[1] })
      $hit = $null
      foreach ($u in $urls) {
        try { $h = ([Uri]$u).Host.ToLowerInvariant() } catch { continue }
        foreach ($d in $domainToService.Keys) { if ($h -eq $d -or $h.EndsWith('.' + $d)) { $hit = $domainToService[$d]; break } }
        if ($hit) { break }
      }
      if (-not $hit) { continue }
      if (-not $perService.ContainsKey($hit)) { $perService[$hit] = 0 }
      $perService[$hit]++
      $ext = $file.Extension.ToLowerInvariant(); if (-not $ext) { $ext = '(none)' }
      if (-not $types.ContainsKey($ext)) { $types[$ext] = 0 }
      $types[$ext]++
      if ($null -eq $newest -or $file.LastWriteTimeUtc -gt $newest) { $newest = $file.LastWriteTimeUtc }
      Note-Service $hit 'downloaded files'
    }
  }
  $total = 0; foreach ($v in $perService.Values) { $total += $v }
  if ($partial -and $total -eq 0) { return [ordered]@{ present = $null; partial = $true; files = 0; files_checked = $checked; note = 'Download folders were partly searched. No matching download was found in the part checked.' } }
  return [ordered]@{
    present = ($total -gt 0); partial = $partial; files = $total; files_checked = $checked; newest = (Iso $newest)
    by_service = @($perService.Keys | Sort-Object | ForEach-Object { [ordered]@{ service = $_; name = $serviceNames[$_]; files = $perService[$_] } })
    by_type = @($types.Keys | Sort-Object | ForEach-Object { [ordered]@{ type = $_; files = $types[$_] } })
  }
}

# ----------------------------------------------------------------------------------------------- clock
function Get-RetentionSetting($clock) {
  if (-not ($clock.PSObject.Properties.Name -contains 'setting')) { return $null }
  $f = Expand-Token $clock.setting.file
  if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { return $null }
  # A settings file is small; a planted huge one must not stall the check.
  if ((Get-Item -LiteralPath $f -Force).Length -gt 1MB) { return $null }
  try {
    $json = [IO.File]::ReadAllText($f) | ConvertFrom-Json
    $v = $json.($clock.setting.key)
    if ($null -ne $v) { return [double]$v }
  } catch { }
  return $null
}

function Fmt-Date($dt) { return (Local-Date $dt).ToString('d MMM yyyy', $Inv) }
function Fmt-Span([double]$hours) {
  if ($hours -lt 48) { return [string]::Format($Inv, '{0:N0} hours', [Math]::Max(1, $hours)) }
  return [string]::Format($Inv, '{0:N0} days', ($hours / 24))
}

function Get-Clock($item, $result) {
  $c = $item.clock
  $newest = $null
  if ($result.Contains('summary') -and $result.summary) { $newest = [datetime]::Parse($result.summary.newest).ToUniversalTime() }
  switch ($c.type) {
    'persistent' {
      return [ordered]@{ status = 'stable'; headline = "Present after $($c.observed_days) days in the cited lab run"; detail = $c.note }
    }
    'until_deleted' {
      return [ordered]@{ status = 'stable'; headline = 'The download mark may remain while the file stays in place'; detail = $c.note }
    }
    'until_user_deletes' {
      # Kept indefinitely only while nobody deletes it in the app; one deletion removes it within hours. For a
      # legal hold that is "at risk", not "stays".
      return [ordered]@{ status = 'urgent'; headline = "At risk when the $($c.unit) is deleted in the app"; detail = $c.note }
    }
    'rolling' {
      $days = [double]$c.days
      $custom = Get-RetentionSetting $c
      $settingNote = ''
      if ($null -ne $custom) {
        if ($custom -le 0) { return [ordered]@{ status = 'stable'; headline = 'Automatic deletion switched off on this computer'; detail = "$($c.note) The retention setting here is $custom." } }
        $days = $custom; $settingNote = " This computer's setting: $custom days."
      }
      $cutoff = $nowUtc.AddDays(-$days)
      $detail = "$($c.note)$settingNote Today the limit falls on $(Fmt-Date $cutoff); it moves forward every day."
      $files = @($(if ($rawFiles.ContainsKey($item.id)) { $rawFiles[$item.id] } else { @() }))
      if ($files.Count) {
        # Files already past the window but still here: the clean-up has not removed them (yet). Report what is
        # observed, not what the rule says should have happened.
        $over = @($files | Where-Object { $_.LastWriteTimeUtc -lt $cutoff })
        if ($over.Count) {
          return [ordered]@{ status = 'urgent'; headline = "$($over.Count) item(s) are older than the $days-day limit and still here"; overdue = $over.Count
            detail = "$detail These may be removed at any time: preserve them now." }
        }
        $oldest = ($files | Sort-Object LastWriteTimeUtc | Select-Object -First 1).LastWriteTimeUtc
        $due = $oldest.AddDays($days)
        $left = ($due - $nowUtc).TotalHours
        $status = 'rolling'; if ($left -le 7 * 24) { $status = 'urgent' }
        return [ordered]@{ status = $status; headline = "Oldest item reaches the $days-day reference window in about $(Fmt-Span $left)"; deadline = (Iso $due); detail = $detail }
      }
      return [ordered]@{ status = 'rolling'; headline = "Reference window: about $days days"; detail = $detail }
    }
    'short' {
      if ($null -eq $newest) {
        return [ordered]@{ status = 'urgent'; headline = "Lasts about $($c.min_days) to $($c.max_days) days"; detail = $c.note }
      }
      $age = ($nowUtc - $newest).TotalHours
      if ($age -le [double]$c.min_days * 24) {
        $left = [double]$c.min_days * 24 - $age
        return [ordered]@{ status = 'urgent'; headline = "Recent activity may disappear within about $(Fmt-Span $left)"; deadline = (Iso $newest.AddDays([double]$c.min_days)); detail = $c.note }
      }
      if ($age -le [double]$c.max_days * 24) {
        return [ordered]@{ status = 'urgent'; headline = 'May already be disappearing'; deadline = (Iso $newest.AddDays([double]$c.max_days)); detail = $c.note }
      }
      return [ordered]@{ status = 'likely_gone'; headline = "Last activity is older than the $($c.max_days)-day lab window; check the source detail"; detail = $c.note }
    }
    'unreliable' { return [ordered]@{ status = 'unreliable'; headline = 'Not a reliable source of chat text'; detail = $c.note } }
    'cloud_deletion' { return [ordered]@{ status = 'cloud'; headline = "Vendor describes a $($c.days)-day deletion window; see stated exceptions"; detail = $c.note } }
    'cloud_autodelete' { return [ordered]@{ status = 'cloud'; headline = 'Account activity follows its auto-delete setting; see vendor exceptions'; detail = $c.note } }
    default { return [ordered]@{ status = 'unknown'; headline = 'Lifetime not measured yet'; detail = 'Treat as at risk until measured.' } }
  }
}

# ----------------------------------------------------------------------------------------------- run
Write-Host "LUMINOL Check $LuminolVersion - looking for AI evidence on this computer..." -ForegroundColor Cyan
$results = New-Object System.Collections.ArrayList
$cloudItems = @()
$itemCount = @($catalog.items).Count
$itemIndex = 0
foreach ($item in $catalog.items) {
  $itemIndex++
  if ($item.detect.kind -eq 'service_seen') { $cloudItems += $item; continue }
  Write-Host "  checking: $($item.evidence)"
  Set-Progress "Checking: $($item.evidence)" (5 + 85 * $itemIndex / $itemCount)
  try {
    switch ($item.detect.kind) {
      'files'           { $r = Detect-Files $item }
      'browser_history' { $r = Detect-BrowserHistory $item }
      'site_storage'    { $r = Detect-SiteStorage $item }
      'needles'         { $r = Detect-Needles $item }
      'downloads'       { $r = Detect-Downloads $item }
      default           { $r = [ordered]@{ present = $null; note = "unknown check type $($item.detect.kind)" } }
    }
  } catch {
    $safeMessage = Hide-Profile $_.Exception.Message
    $r = [ordered]@{ present = $null; note = "Check failed: $safeMessage" }
    [void]$problems.Add("$($item.evidence): $safeMessage")
  }
  if ($r.present -eq $true -and $item.service -and $item.service -ne '*') { Note-Service $item.service $item.tool }
  [void]$results.Add([ordered]@{ item = $item; result = $r })
}
foreach ($item in $cloudItems) {
  $seen = $servicesSeen.ContainsKey($item.detect.service)
  $r = [ordered]@{ present = $seen; seen_in = @($(if ($seen) { $servicesSeen[$item.detect.service] } else { @() })) }
  [void]$results.Add([ordered]@{ item = $item; result = $r })
}

$rank = @{ 'urgent' = 0; 'rolling' = 1; 'cloud' = 2; 'unknown' = 3; 'unreliable' = 4; 'stable' = 5; 'likely_gone' = 6 }
$evidence = New-Object System.Collections.ArrayList
foreach ($x in $results) {
  $item = $x.item; $r = $x.result
  $entry = [ordered]@{
    id = $item.id; tool = $item.tool; service = $item.service; evidence = $item.evidence; why = $item.why
    present = $r.present; result = $r; source = $item.source
    also_sources = @($(if ($item.PSObject.Properties.Name -contains 'also') { $item.also } else { @() }))
    action = $item.action; clock = $null
  }
  if ($r.present -eq $true) { $entry.clock = Get-Clock $item $r }
  [void]$evidence.Add($entry)
}
$present = @($evidence | Where-Object { $_.present -eq $true } | Sort-Object { $rank[$_.clock.status] }, { if ($_.clock.Contains('deadline')) { $_.clock.deadline } else { 'z' } })
$absent = @($evidence | Where-Object { $_.present -eq $false })
$unreadable = @($evidence | Where-Object { $null -eq $_.present })

$actions = New-Object System.Collections.ArrayList
foreach ($e in $present) {
  if (@('urgent', 'rolling', 'cloud') -contains $e.clock.status) { [void]$actions.Add([ordered]@{ status = $e.clock.status; tool = $e.tool; text = $e.action; deadline = $(if ($e.clock.Contains('deadline')) { $e.clock.deadline } else { $null }) }) }
}
if ($present.Count -gt 0) {
  [void]$actions.Add([ordered]@{ status = 'hold'; tool = 'Legal hold'; text = 'If this computer may matter in a dispute or investigation: do not delete chats, clear browser history or uninstall AI apps, and add the AI accounts and the locations in this report to the legal hold notice.'; deadline = $null })
}

# Draft preservation notice naming what was actually found (the "act" step).
$holdItems = New-Object System.Collections.ArrayList
$holdSeen = @{}
foreach ($e in $present) {
  $it = @($catalog.items | Where-Object { $_.id -eq $e.id })[0]
  if (-not ($it.PSObject.Properties.Name -contains 'hold')) { continue }
  $key = $e.tool
  if ($holdSeen.ContainsKey($key)) {
    if ($holdItems[$holdSeen[$key]].instruction -notlike "*$($it.hold)*") { $holdItems[$holdSeen[$key]].instruction += ' ' + $it.hold }
  } else {
    $holdSeen[$key] = $holdItems.Count
    [void]$holdItems.Add([ordered]@{ tool = $key; instruction = $it.hold })
  }
}
$holdText = $null
$clockLines = @()
if ($holdItems.Count) {
  $lines = @('AI PRESERVATION NOTICE - DRAFT FOR COUNSEL TO ADAPT',
    "Prepared from a LUMINOL check of this computer on $((Local-Date $nowUtc).ToString('d MMMM yyyy', $Inv)) (Windows account shown as %USERPROFILE%).",
    'Until you are told otherwise in writing, preserve all information created with or by AI tools, including the following found on this computer:')
  $n = 0
  foreach ($h in $holdItems) { $n++; $lines += "$n. $($h.tool): $($h.instruction)" }
  foreach ($e in $present) {
    $it = @($catalog.items | Where-Object { $_.id -eq $e.id })[0]
    if (@('none', 'unknown') -contains $it.clock.type -or $e.source -eq 'NOT-MEASURED') { continue }
    $sourceKind = $catalog.sources.($e.source).kind
    $sourceLabel = switch ($sourceKind) { 'measured' { 'Lab measurement' } 'vendor' { 'Vendor policy' } 'design' { 'System design' } default { $null } }
    if (-not $sourceLabel) { continue }
    $sentence = [string]$e.clock.headline
    if (-not $sentence) { continue }
    $sentence = $sentence.Substring(0, 1).ToLowerInvariant() + $sentence.Substring(1).TrimEnd('.') + '.'
    $clockLines += "$($e.tool) - $($e.evidence): $sentence ($sourceLabel)."
  }
  if ($clockLines.Count) {
    $lines += 'Records may disappear while this notice is in effect:'
    $lines += $clockLines
    $lines += 'A preservation notice cannot stop automatic deletion: collect these items promptly.'
  }
  $lines += 'Also preserve AI tools and accounts used on other devices (phones, home computers) and anything not listed here: this check covers this Windows account on this computer.'
  $lines += 'Do not change retention or auto-delete settings, delete, reset or uninstall anything listed without written instructions from counsel.'
  $lines += 'This notice is a draft for your counsel to adapt.'
  $holdText = $lines -join "`n"
}

$os = $null
try { $o = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop; $os = [ordered]@{ name = $o.Caption; version = $o.Version; build = $o.BuildNumber } } catch { $os = [ordered]@{ name = 'Windows'; version = [Environment]::OSVersion.Version.ToString(); build = '' } }

$lastAccessRaw = $null
try {
  if ($LastAccessRawForTest) {
    if ($LastAccessRawForTest -ne 'unknown') { $lastAccessRaw = [long]::Parse($LastAccessRawForTest, $Inv) }
  } else {
    $lastAccessRaw = [long](Get-ItemPropertyValue -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name 'NtfsDisableLastAccessUpdate' -ErrorAction Stop)
  }
} catch { $lastAccessRaw = $null }
$lastAccess = [ordered]@{ raw = $lastAccessRaw; enabled = $null; system_managed = $null }
if ($null -ne $lastAccessRaw) {
  $lastAccess.enabled = (($lastAccessRaw -band 1) -eq 0)
  $lastAccess.system_managed = (($lastAccessRaw -band 0x80000000L) -ne 0)
}
$lastAccessMessage = if ($null -eq $lastAccess.enabled) {
  'LUMINOL could not tell whether Windows records last-opened times on this computer; if it does, this check updated them for the files and folders it read.'
} elseif ($lastAccess.enabled) {
  'Windows on this computer records when files are last opened, so this check updated the last-access time of the files and folders it read. It changed nothing else about them.'
} else {
  'Windows on this computer does not record when files are last opened, so this check left those times as they were.'
}

# The report folder must be writable before the report is built (Documents can be a full, offline or read-only
# network/OneDrive folder). Default folder: fall back to the Desktop, then TEMP, and say so in the report.
if (-not (Test-Writable $OutDir)) {
  if ($outDirGiven) {
    $msg = "LUMINOL cannot write the report to $OutDir (no permission, or the drive is unavailable). No report was written."
    Write-Host $msg -ForegroundColor Red; if ($null -ne $ProgressSink) { $ProgressSink['error'] = $msg }; exit 4
  }
  $fallback = Join-Path ([Environment]::GetFolderPath('Desktop')) 'LUMINOL'
  if (-not (Test-Writable $fallback)) { $fallback = Join-Path $env:TEMP 'LUMINOL' }
  [void]$problems.Add("Documents\LUMINOL could not be written to, so this report was saved in $(Hide-Profile $fallback) instead.")
  $OutDir = $fallback
}

$usedSources = @{}
# Every source referenced by any item in the report (found, not found or not checked), so each id is linkable.
foreach ($e in $evidence) { $usedSources[$e.source] = 1; foreach ($s in $e.also_sources) { $usedSources[$s] = 1 } }
$sources = @($usedSources.Keys | Sort-Object | ForEach-Object {
  $s = $catalog.sources.$_
  [ordered]@{ id = $_; label = $s.label; kind = $s.kind; url = $(if ($s.PSObject.Properties.Name -contains 'url') { $s.url } else { $null }) }
})

$report = [ordered]@{
  schema = 'luminol.check/1'
  luminol_version = $LuminolVersion
  catalog_version = $catalog.catalog_version
  generated_at = (Iso $nowUtc)
  sample_data = [bool]$SampleData
  run_settings = [ordered]@{ non_default = ($nonDefaultNames.Count -gt 0); parameters = @($nonDefaultNames) }
  generated_local = (Local-Date $nowUtc).ToString('dddd d MMMM yyyy, HH:mm', $Inv)
  duration_seconds = $(if ($SampleData) { 0 } else { [Math]::Round(((Get-Date) - $started).TotalSeconds, 1) })
  computer = [ordered]@{ os = $os; powershell = $PSVersionTable.PSVersion.ToString(); profile = '%USERPROFILE%' }
  last_access_updates = $lastAccess
  last_access_message = $lastAccessMessage
  absence_note = 'Not found does not mean AI was not used. Cleared browser history, private (InPrivate or Incognito) windows, another browser or Windows account, a phone or another computer leave nothing here for LUMINOL to find, and LUMINOL cannot tell whether history was cleared.'
  browsers_open = @($browsersOpen)
  summary = [ordered]@{
    evidence_found = $present.Count
    urgent = @($present | Where-Object { $_.clock.status -eq 'urgent' }).Count
    services_seen = @($servicesSeen.Keys | Sort-Object | ForEach-Object { [ordered]@{ id = $_; name = $serviceNames[$_]; seen_in = @($servicesSeen[$_]) } })
    not_found = $absent.Count
    could_not_check = $unreadable.Count
    partial_checks = $partialChecks.Count
  }
  actions = @($actions)
  hold_notice = [ordered]@{ items = @($holdItems); clock_lines = @($clockLines); text = $holdText }
  evidence = @($present) + @($unreadable) + @($absent)
  cannot_answer = @($catalog.cannot_answer) + @($partialChecks)
  lab_note = $catalog.lab_note
  sources = $sources
  problems = @($problems)
  privacy = $(if ($Timestamp) { "This report was made on this computer. LUMINOL read file names, sizes and dates, and checked whether AI site names appear in a few files. It did not read conversation text. $lastAccessMessage Because you asked for a timestamp, a 32-byte fingerprint of this report, mixed with a random number, was sent to public OpenTimestamps calendars (see the .seal.json file)." } else { "This report was made on this computer. LUMINOL read file names, sizes and dates, and checked whether AI site names appear in a few files. It did not read conversation text. $lastAccessMessage Running the check sent nothing over the internet. If you choose to timestamp this report later, a fingerprint of it is sent (see the .seal.json file)." })
  timestamp_requested = [bool]$Timestamp
}

$json = $report | ConvertTo-Json -Depth 12
$safe = $json.Replace('</', '<\/')
$html = $template.Replace('/*__LUMINOL_DATA__*/null', $safe)
if (-not (Test-Path -LiteralPath $OutDir)) { [void](New-Item -ItemType Directory -Path $OutDir -Force) }
$stamp = (Local-Date $nowUtc).ToString('yyyy-MM-dd_HHmmss', $Inv) + '_' + [guid]::NewGuid().ToString('N')
$htmlPath = Join-Path $OutDir "LUMINOL-Check_$stamp.html"
$jsonPath = Join-Path $OutDir "LUMINOL-Check_$stamp.json"
$utf8 = New-Object Text.UTF8Encoding($false)
$htmlFile = [IO.File]::Open($htmlPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
try {
  $writer = New-Object IO.StreamWriter($htmlFile, $utf8)
  try { $writer.Write($html) } finally { $writer.Dispose() }
} finally { $htmlFile.Dispose() }
$jsonFile = [IO.File]::Open($jsonPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
try {
  $writer = New-Object IO.StreamWriter($jsonFile, $utf8)
  try { $writer.Write($json) } finally { $writer.Dispose() }
} finally { $jsonFile.Dispose() }
if ($null -ne $ProgressSink) { $ProgressSink['html'] = $htmlPath; $ProgressSink['json'] = $jsonPath; $ProgressSink['done'] = $true }
if ($Timestamp) {
  Set-Progress 'Requesting a pending timestamp proof' 95
  . (Join-Path $here 'Luminol-Seal.ps1')
  $sealArgs = @{ Files = @($htmlPath, $jsonPath) }
  $cals = @($TimestampCalendars | ForEach-Object { $_ -split ',' } | Where-Object { $_ })  # one comma list is fine too
  if ($cals.Count) { $sealArgs.Calendars = $cals }
  $seal = New-LuminolSeal @sealArgs
  if ($null -ne $ProgressSink) { $ProgressSink['seal'] = $seal.seal; $ProgressSink['proofs'] = @($seal.proofs); $ProgressSink['seal_errors'] = @($seal.errors) }
  if (@($seal.proofs).Count) { Write-Host "Timestamp proofs: $(@($seal.proofs).Count) saved next to the report ($($seal.calendars -join ', '))" -ForegroundColor Green }
  else { Write-Host "Timestamp failed (offline?): $($seal.errors -join '; '). The report itself is complete." -ForegroundColor Yellow }
}
Set-Progress 'Done' 100

Write-Host ''
Write-Host "Evidence found: $($present.Count)   Urgent: $($report.summary.urgent)   AI services seen: $(@($servicesSeen.Keys).Count)" -ForegroundColor Green
Write-Host "Report: $htmlPath"
if ($problems.Count) { Write-Host "Notes: $($problems.Count) item(s) could not be fully checked (see the report)." -ForegroundColor Yellow }
if (-not $NoOpen) { Start-Process $htmlPath }
