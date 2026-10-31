<#
.SYNOPSIS
  LUMINOL sealed snapshot (opt-in): requests a proof of a report fingerprint.

.DESCRIPTION
  Writes <report>.seal.json listing the SHA-256 fingerprint of each report file, then asks two public OpenTimestamps
  calendars to timestamp the fingerprint of that seal file. Returned proofs begin pending and need later upgrade and
  verification before a Bitcoin timestamp claim. The request body contains one randomized 32-byte fingerprint;
  calendars also receive ordinary connection metadata such as an IP address. A request is made when the person
  selects Timestamp or runs Luminol-Check.ps1 -Timestamp.

  Proof files: <report>.seal.json.ots (first calendar) and <report>.seal.json.2.ots (second calendar), standard
  OpenTimestamps files. Check them with the OpenTimestamps client:  ots verify <report>.seal.json.ots
  (after a few hours, run  ots upgrade <report>.seal.json.ots  first to add the Bitcoin confirmation).
#>

# Order matters: two independent operators first (OpenTimestamps, Eternitywall), both reachable with TLS 1.2 from
# Windows 10's built-in PowerShell. a.pool accepts only TLS 1.3 (Windows 11), so it is the later fallback.
$LuminolCalendars = @('https://b.pool.opentimestamps.org', 'https://finney.calendar.eternitywall.com', 'https://bob.btc.calendar.opentimestamps.org', 'https://a.pool.opentimestamps.org')

function Get-Sha256Bytes([byte[]]$data) {
  $h = [Security.Cryptography.SHA256]::Create()
  try { return $h.ComputeHash($data) } finally { $h.Dispose() }
}
function ConvertTo-Hex([byte[]]$b) { return -join ($b | ForEach-Object { $_.ToString('x2') }) }

# Standard detached OpenTimestamps file: header, SHA-256 file digest, then append(nonce) + sha256 + calendar reply.
function New-OtsFile([byte[]]$digest, [byte[]]$nonce, [byte[]]$reply) {
  $magic = [byte[]](0x00) + [Text.Encoding]::ASCII.GetBytes('OpenTimestamps') + [byte[]](0x00, 0x00) + [Text.Encoding]::ASCII.GetBytes('Proof') +
           [byte[]](0x00, 0xbf, 0x89, 0xe2, 0xe8, 0x84, 0xe8, 0x92, 0x94)
  return [byte[]]($magic + [byte[]](0x01, 0x08) + $digest + [byte[]](0xf0, [byte]$nonce.Length) + $nonce + [byte[]](0x08) + $reply)
}

function Invoke-Calendar([string]$calendar, [byte[]]$commitment, [int]$timeoutMs) {
  $req = [Net.HttpWebRequest]::Create("$calendar/digest")
  $req.Method = 'POST'
  $req.Timeout = $timeoutMs
  $req.ReadWriteTimeout = $timeoutMs
  $req.Accept = 'application/vnd.opentimestamps.v1'
  $req.ContentType = 'application/x-www-form-urlencoded'
  $req.UserAgent = 'LUMINOL-timestamp'
  $req.ContentLength = $commitment.Length
  $s = $req.GetRequestStream(); try { $s.Write($commitment, 0, $commitment.Length) } finally { $s.Dispose() }
  $resp = $req.GetResponse()
  try {
    $ms = New-Object IO.MemoryStream
    $rs = $resp.GetResponseStream(); try { $rs.CopyTo($ms) } finally { $rs.Dispose() }
    $bytes = $ms.ToArray()
  } finally { $resp.Dispose() }
  if ($bytes.Length -lt 10 -or $bytes.Length -gt 10000) { throw "unexpected reply size $($bytes.Length)" }
  return ,$bytes
}

<#
  New-LuminolSeal -Files <report.html>,<report.json> [-Calendars ...]
  Returns @{ seal = <path>; proofs = @(<paths>); calendars = @(<used>); errors = @(<calendar: message>); sent = <hex> }
#>
function New-LuminolSeal {
  param([string[]]$Files, [string[]]$Calendars = $LuminolCalendars, [int]$Want = 2, [int]$TimeoutMs = 15000)
  $first = $Files[0]
  $base = [IO.Path]::Combine([IO.Path]::GetDirectoryName($first), [IO.Path]::GetFileNameWithoutExtension($first))
  $entries = @()
  foreach ($f in $Files) {
    $bytes = [IO.File]::ReadAllBytes($f)
    $entries += [ordered]@{ file = [IO.Path]::GetFileName($f); bytes = $bytes.Length; sha256 = (ConvertTo-Hex (Get-Sha256Bytes $bytes)) }
  }
  $seal = [ordered]@{
    schema = 'luminol.seal/1'
    created_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
    files = $entries
    method = 'SHA-256 of each report file; a randomized fingerprint of this seal file was submitted to OpenTimestamps. Returned proofs begin pending and need later upgrade and verification.'
    sent = 'The request body sent one randomized 32-byte fingerprint to the calendars below, without report content. The calendars also received ordinary connection metadata such as an IP address.'
    verify = 'ots upgrade <this file>.ots (after a few hours), then ots verify <this file>.ots. Also confirm each file''s SHA-256 above.'
  }
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  $sealPath = "$base.seal.json"
  $sealText = $seal | ConvertTo-Json -Depth 5
  [IO.File]::WriteAllText($sealPath, $sealText, (New-Object Text.UTF8Encoding($false)))
  $digest = Get-Sha256Bytes ([IO.File]::ReadAllBytes($sealPath))
  $nonce = New-Object byte[] 16
  $rng = [Security.Cryptography.RandomNumberGenerator]::Create(); try { $rng.GetBytes($nonce) } finally { $rng.Dispose() }
  $commitment = Get-Sha256Bytes ([byte[]]($digest + $nonce))
  $proofs = @(); $used = @(); $errors = @()
  foreach ($cal in $Calendars) {
    if ($proofs.Count -ge $Want) { break }
    try {
      $reply = Invoke-Calendar $cal $commitment $TimeoutMs
      $suffix = $(if ($proofs.Count -eq 0) { '' } else { ".$($proofs.Count + 1)" })
      $otsPath = "$sealPath$suffix.ots"
      [IO.File]::WriteAllBytes($otsPath, (New-OtsFile $digest $nonce $reply))
      $proofs += $otsPath; $used += $cal
    } catch {
      $errors += "$cal : $($_.Exception.Message)"
    }
  }
  return @{ seal = $sealPath; proofs = $proofs; calendars = $used; errors = $errors; sent = (ConvertTo-Hex $commitment); digest = (ConvertTo-Hex $digest) }
}
