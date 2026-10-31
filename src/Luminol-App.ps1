<#
.SYNOPSIS
  LUMINOL app window: runs LUMINOL Check in the background and shows its results in a window.

.DESCRIPTION
  The window's logic. Its look lives in ui\MainWindow.xaml. The window shows exactly what the check wrote to
  its JSON report: nothing is computed here that the report does not contain. Same promise as the check: no
  installation, no administrator rights, no network, read-only. If the window cannot be shown, the plain check runs
  instead and opens its HTML report, so LUMINOL never fails silently.

  Start with LUMINOL.cmd (which runs:  powershell -NoProfile -ExecutionPolicy Bypass -STA -File Luminol-App.ps1).

.PARAMETER SelfTest
  No visible window: run the check, fill the window off-screen and write what each element shows to -SelfTestOut
  (JSON). Used by the automated tests.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
  [switch]$SelfTest,
  [string]$SelfTestOut = '',
  [string]$SelfTestShot = '',
  [string]$ProfileRoot = '',
  [string]$OutDir = '',
  [string]$Now = '',
  [switch]$NoOpen,
  [switch]$SelfTestTimestamp,
  [string[]]$Calendars = @(),
  [string[]]$BrowserProcessesForTest = $null
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$checkPath = Join-Path $here 'Luminol-Check.ps1'
$xamlPath = Join-Path $here 'ui\MainWindow.xaml'
$iconPath = Join-Path $here 'ui\assets\luminol.ico'
if (-not $OutDir) { $OutDir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'LUMINOL' }

# Element contract (docs/APP_PLAN.md): name -> required WPF type.
$Contract = [ordered]@{
  CheckButton = 'Button'; ProgressBar = 'ProgressBar'; StatusText = 'TextBlock'
  SummaryEvidence = 'TextBlock'; SummaryUrgent = 'TextBlock'; SummaryServices = 'TextBlock'; SummaryCouldNotCheck = 'TextBlock'; SummaryAbsenceNote = 'TextBlock'; RunSettingsText = 'TextBlock'
  ActionsList = 'ItemsControl'; EvidenceList = 'ItemsControl'; CannotAnswerList = 'ItemsControl'; SourcesList = 'ItemsControl'
  PrivacyText = 'TextBlock'; OpenReportButton = 'Button'; OpenFolderButton = 'Button'; CopySummaryButton = 'Button'
  PreserveButton = 'Button'; ErrorPanel = 'Border'; ErrorText = 'TextBlock'
  ResultsOverview = 'Grid'; EvidenceDetailView = 'Grid'; BackToResultsButton = 'Button'; DetailScroll = 'ScrollViewer'
  DetailSource = 'TextBlock'; DetailTitle = 'TextBlock'; DetailStatus = 'TextBlock'; DetailObserved = 'ItemsControl'
  DetailWhy = 'TextBlock'; DetailAbsence = 'TextBlock'; DetailDoesNotEstablish = 'TextBlock'
  DetailLifetime = 'StackPanel'; DetailClockStatus = 'TextBlock'; DetailClockHeadline = 'TextBlock'; DetailClockDeadline = 'TextBlock'; DetailClockDetail = 'TextBlock'
  DetailAction = 'TextBlock'; DetailSources = 'ItemsControl'; DetailCompleted = 'TextBlock'; DetailSettings = 'TextBlock'
  DetailPartial = 'Border'; DetailProblems = 'ItemsControl'
}
$OptionalHooks = @('ReportPathText', 'ResultsTabs', 'LabNoteText', 'TimestampButton', 'TimestampText', 'CopyNoticeButton', 'HoldNoticeText')
$sealPath = Join-Path $here 'Luminol-Seal.ps1'
$Calendars = @($Calendars | ForEach-Object { $_ -split ',' } | Where-Object { $_ })

$script:window = $null
$script:ui = @{}
$script:report = $null
$script:paths = @{ html = $null; json = $null }
$script:run = $null
$script:sealRun = $null
$script:sealed = $false
$script:browserWarning = ''

function Get-BrowserWarning {
  $names = [ordered]@{ chrome = 'Chrome'; msedge = 'Edge'; firefox = 'Firefox'; brave = 'Brave'; opera = 'Opera'; vivaldi = 'Vivaldi'; arc = 'Arc' }
  $running = if ($null -ne $BrowserProcessesForTest) { @($BrowserProcessesForTest | ForEach-Object { $_ -split ',' }) } else { @(Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessName }) }
  $found = @($names.Keys | Where-Object { $running -contains $_ } | ForEach-Object { $names[$_] })
  if (-not $found.Count) { return '' }
  return (@($found | ForEach-Object { "$_ is open, so its history is locked and may be reported as unreadable. Close it for a complete check, or continue." }) -join "`n")
}

function Confirm-BrowserOpen([string]$warning) {
  $dialog = New-Object Windows.Window
  $dialog.Title = 'LUMINOL browser check'
  $dialog.Width = 500; $dialog.Height = 190
  $dialog.WindowStartupLocation = [Windows.WindowStartupLocation]::CenterOwner
  $dialog.Owner = $script:window
  $dialog.ResizeMode = [Windows.ResizeMode]::NoResize
  $panel = New-Object Windows.Controls.StackPanel
  $panel.Margin = New-Object Windows.Thickness 20
  $label = New-Object Windows.Controls.TextBlock
  $label.Text = $warning; $label.TextWrapping = [Windows.TextWrapping]::Wrap
  [void]$panel.Children.Add($label)
  $buttons = New-Object Windows.Controls.StackPanel
  $buttons.Orientation = [Windows.Controls.Orientation]::Horizontal
  $buttons.HorizontalAlignment = [Windows.HorizontalAlignment]::Right
  $buttons.Margin = New-Object Windows.Thickness 0,20,0,0
  $again = New-Object Windows.Controls.Button
  $again.Content = 'Check again'; $again.Padding = New-Object Windows.Thickness 12,6,12,6
  $again.Add_Click({ $dialog.DialogResult = $false; $dialog.Close() })
  [void]$buttons.Children.Add($again)
  $continue = New-Object Windows.Controls.Button
  $continue.Content = 'Continue'; $continue.Padding = New-Object Windows.Thickness 12,6,12,6
  $continue.Margin = New-Object Windows.Thickness 10,0,0,0
  $continue.Add_Click({ $dialog.DialogResult = $true; $dialog.Close() })
  [void]$buttons.Children.Add($continue)
  [void]$panel.Children.Add($buttons)
  $dialog.Content = $panel
  return [bool]$dialog.ShowDialog()
}

# ------------------------------------------------------------------------------------------------ fallback
function Start-PlainCheck([string]$why) {
  Write-Host "LUMINOL: the app window could not be shown ($why). Running the plain check; the report opens in your browser." -ForegroundColor Yellow
  $args2 = @{ OutDir = $OutDir }
  if ($ProfileRoot) { $args2.ProfileRoot = $ProfileRoot }
  if ($Now) { $args2.Now = $Now }
  if ($NoOpen) { $args2.NoOpen = $true }
  if ($null -ne $BrowserProcessesForTest) { $args2.BrowserProcessesForTest = $BrowserProcessesForTest }
  try {
    & $checkPath @args2
  } catch {
    # Last resort, so a hidden-console launch never fails without a word.
    $msg = "LUMINOL could not run.`n`nWindow: $why`nCheck: $($_.Exception.Message)`n`nKeep all files from the download together and try 'Run LUMINOL Check.cmd'."
    try { Add-Type -AssemblyName System.Windows.Forms; [void][Windows.Forms.MessageBox]::Show($msg, 'LUMINOL') } catch { Write-Host $msg -ForegroundColor Red }
  }
}

# ------------------------------------------------------------------------------------------------ window
function Initialize-Window {
  Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
  [xml]$xaml = [IO.File]::ReadAllText($xamlPath, [Text.Encoding]::UTF8)
  # Resolve bundled brand fonts beside the XAML, independent of the launch directory.
  $parserContext = New-Object Windows.Markup.ParserContext
  $parserContext.BaseUri = [Uri]::new([IO.Path]::GetFullPath($xamlPath))
  $xamlStream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($xaml.OuterXml))
  try { $script:window = [Windows.Markup.XamlReader]::Load($xamlStream, $parserContext) }
  finally { $xamlStream.Dispose() }
  # WPF sizes are device-independent units. Keep the window inside the usable desktop at high display scaling.
  $work = [Windows.SystemParameters]::WorkArea
  $script:window.MinWidth = [Math]::Min($script:window.MinWidth, $work.Width)
  $script:window.MinHeight = [Math]::Min($script:window.MinHeight, $work.Height)
  $script:window.Width = [Math]::Max($script:window.MinWidth, [Math]::Min(1320, $work.Width * 0.9))
  $script:window.Height = [Math]::Max($script:window.MinHeight, [Math]::Min(940, $work.Height * 0.92))
  # On a small laptop screen (for example 1366x768) even 90% of the desktop leaves almost no room for the findings list.
  if ($work.Height -lt 800 -or $work.Width -lt 1100) { $script:window.WindowState = [Windows.WindowState]::Maximized }
  foreach ($name in $Contract.Keys) {
    $c = $script:window.FindName($name)
    if ($null -eq $c -or $c.GetType().Name -ne $Contract[$name]) { throw "window element '$name' ($($Contract[$name])) is missing" }
    $script:ui[$name] = $c
  }
  foreach ($name in $OptionalHooks) { $script:ui[$name] = $script:window.FindName($name) }
  if (Test-Path -LiteralPath $iconPath) {
    try { $script:window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create((New-Object Uri ((Resolve-Path -LiteralPath $iconPath).Path))) } catch { }
  }
  Set-State 'Ready' 'Ready to check'
  $script:ui.PreserveButton.IsEnabled = $false   # Preserve mode does not exist yet (November)
  $script:ui.CheckButton.Add_Click({ Start-Check })
  $script:ui.BackToResultsButton.Add_Click({ Close-EvidenceDetail })
  $script:ui.EvidenceList.AddHandler([Windows.Controls.Button]::ClickEvent, [Windows.RoutedEventHandler]{
    param($sender, $event)
    $button = $event.OriginalSource
    if ($button -is [Windows.Controls.Button] -and $button.Tag -eq 'EvidenceDetail') {
      $script:detailOrigin = $button
      Show-EvidenceDetail $button.DataContext
      $event.Handled = $true
    }
  })
  $script:ui.OpenReportButton.Add_Click({ if ($script:paths.html -and (Test-Path -LiteralPath $script:paths.html)) { Start-Process -FilePath $script:paths.html } })
  $script:ui.OpenFolderButton.Add_Click({
    if ($script:paths.html -and (Test-Path -LiteralPath $script:paths.html)) { Start-Process -FilePath "$env:SystemRoot\explorer.exe" -ArgumentList "/select,`"$($script:paths.html)`"" }
    elseif (Test-Path -LiteralPath $OutDir) { Start-Process -FilePath "$env:SystemRoot\explorer.exe" -ArgumentList "`"$OutDir`"" }
  })
  if ($script:ui.TimestampButton) { $script:ui.TimestampButton.Add_Click({ Start-Timestamp }) }
  if ($script:ui.CopyNoticeButton) {
    $script:ui.CopyNoticeButton.Add_Click({
      if ($script:report -and (Has $script:report 'hold_notice') -and $script:report.hold_notice.text) {
        try { [Windows.Clipboard]::SetText([string]$script:report.hold_notice.text); $script:ui.StatusText.Text = 'Draft preservation notice copied to the clipboard.' } catch { $script:ui.StatusText.Text = 'Could not copy to the clipboard.' }
      }
    })
  }
  $script:ui.CopySummaryButton.Add_Click({
    if ($script:report) { try { [Windows.Clipboard]::SetText((Get-SummaryText $script:report)); $script:ui.StatusText.Text = 'Summary copied to the clipboard.' } catch { $script:ui.StatusText.Text = 'Could not copy to the clipboard.' } }
  })
}

function Set-State([string]$state, [string]$status) {
  $script:window.Tag = $state
  $script:ui.StatusText.Text = $status
  $running = ($state -eq 'Running')
  $script:ui.CheckButton.IsEnabled = -not $running
  $script:ui.CheckButton.Content = $(if ($state -eq 'Results') { 'Check again' } else { 'Check this computer' })
  if ($running) { $script:ui.ProgressBar.Value = 0 }
  $hasHtml = [bool]($script:paths.html -and (Test-Path -LiteralPath $script:paths.html))
  $script:ui.OpenReportButton.IsEnabled = $hasHtml -and -not $running
  $script:ui.OpenFolderButton.IsEnabled = $hasHtml -and -not $running
  $script:ui.CopySummaryButton.IsEnabled = ($null -ne $script:report) -and ($state -eq 'Results')
  $script:ui.PreserveButton.IsEnabled = $false
  if ($script:ui.CopyNoticeButton) { $script:ui.CopyNoticeButton.IsEnabled = ($state -eq 'Results') -and ($null -ne $script:report) -and (Has $script:report 'hold_notice') -and [bool]$script:report.hold_notice.text }
  if ($script:ui.TimestampButton) { $script:ui.TimestampButton.IsEnabled = ($state -eq 'Results') -and $hasHtml -and -not $script:sealed -and ($null -eq $script:sealRun) }
  if ($script:ui.TimestampText -and $state -ne 'Results') { $script:ui.TimestampText.Text = '' }
}

# ------------------------------------------------------------------------------------------------ data
function ConvertTo-List($x) { if ($null -eq $x) { return , @() } return , @($x) }
function ConvertTo-LocalTime([string]$iso) {
  if (-not $iso) { return $null }
  return [datetime]::Parse($iso, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()
}
function Has($obj, [string]$name) { return ($null -ne $obj) -and ($null -ne $obj.PSObject.Properties[$name]) }

# The JSON exactly as the check wrote it, with lists made lists and UTC dates shown in local time. Nothing added.
function ConvertTo-ViewModel([string]$jsonText) {
  $d = $jsonText | ConvertFrom-Json
  $d.actions = ConvertTo-List $d.actions
  $d.evidence = ConvertTo-List $d.evidence
  $d.cannot_answer = ConvertTo-List $d.cannot_answer
  $d.sources = ConvertTo-List $d.sources
  $d.problems = ConvertTo-List $d.problems
  $d.summary.services_seen = ConvertTo-List $d.summary.services_seen
  foreach ($a in $d.actions) { if ((Has $a 'deadline') -and $a.deadline) { $a.deadline = ConvertTo-LocalTime $a.deadline } }
  foreach ($e in $d.evidence) {
    if (Has $e 'also_sources') { $e.also_sources = ConvertTo-List $e.also_sources }
    if ((Has $e 'result') -and (Has $e.result 'locations')) { $e.result.locations = ConvertTo-List $e.result.locations }
    if ((Has $e 'clock') -and $e.clock -and (Has $e.clock 'deadline') -and $e.clock.deadline) { $e.clock.deadline = ConvertTo-LocalTime $e.clock.deadline }
  }
  return $d
}

function Show-Report($d) {
  Close-EvidenceDetail
  $script:report = $d
  $script:window.DataContext = $d
  $script:ui.SummaryEvidence.Text = [string]$d.summary.evidence_found
  $script:ui.SummaryUrgent.Text = [string]$d.summary.urgent
  $script:ui.SummaryServices.Text = [string]@($d.summary.services_seen).Count
  $script:ui.SummaryCouldNotCheck.Text = [string]$d.summary.could_not_check
  $script:ui.SummaryAbsenceNote.Text = $(if ((Has $d 'absence_note') -and $d.summary.not_found -gt 0) { [string]$d.absence_note } else { '' })
  $script:ui.RunSettingsText.Text = Get-RunSettingsLine $d
  $script:ui.ActionsList.ItemsSource = $d.actions
  $evidence = New-Object System.Collections.ObjectModel.ObservableCollection[object]
  foreach ($e in $d.evidence) { $evidence.Add($e) }
  # A plain list on purpose: WPF hides the contents of grouped items from UI Automation, so screen readers could not
  # read any finding. Each row names its tool in the SOURCE column.
  $script:ui.EvidenceList.ItemsSource = $evidence
  $script:ui.CannotAnswerList.ItemsSource = $d.cannot_answer
  $script:ui.SourcesList.ItemsSource = $d.sources
  $script:ui.PrivacyText.Text = [string]$d.privacy
  if ($script:ui.LabNoteText) { $script:ui.LabNoteText.Text = [string]$d.lab_note }
  if ($script:ui.HoldNoticeText) { $script:ui.HoldNoticeText.Text = $(if ((Has $d 'hold_notice') -and $d.hold_notice.text) { [string]$d.hold_notice.text } else { '' }) }
  if ($script:ui.ResultsTabs) { $script:ui.ResultsTabs.SelectedIndex = 0 }
  if ($script:ui.ReportPathText) { $script:ui.ReportPathText.Text = "Report: $($script:paths.html)" }
  $note = ''
  if ($d.summary.partial_checks -gt 0) { $note = " - $($d.summary.partial_checks) partial check(s); see full report" }
  elseif (@($d.problems).Count) { $note = " - $(@($d.problems).Count) note(s) in the report" }
  Set-State 'Results' "Done in $($d.duration_seconds) s - report saved$note"
  if ($script:ui.TimestampText) { $script:ui.TimestampText.Text = 'Optional: request a timestamp proof. It starts pending; a 32-byte fingerprint and ordinary connection metadata reach public calendars.' }
}

function Get-ObservedRows($e) {
  # Explicit presentation allowlist: never dump report/computer/account objects.
  # Labels already used by the light report; values remain literal JSON text.
  $rows = New-Object System.Collections.ArrayList
  $labels = [ordered]@{ locations = 'Locations'; found_locations = 'Found locations'; files = 'Files'; bytes = 'Bytes'; newest = 'Newest change'; oldest = 'Oldest change'; modified = 'Last changed'; files_checked = 'Files checked'; names = 'Names'; seen_in = 'Seen in'; note = 'Note' }
  $result = $e.result
  foreach ($key in $labels.Keys) {
    if (Has $result $key) {
      foreach ($value in @($result.$key)) {
        if ($null -ne $value -and $value -isnot [pscustomobject] -and $value -isnot [System.Collections.IDictionary]) {
          [void]$rows.Add([pscustomobject]@{ label = $labels[$key]; value = [string]$value })
        }
      }
    }
  }
  foreach ($key in 'files', 'bytes', 'newest', 'oldest') {
    if (Has $result.summary $key) { [void]$rows.Add([pscustomobject]@{ label = $labels[$key]; value = [string]$result.summary.$key }) }
  }
  foreach ($profile in @($result.profiles)) {
    foreach ($key in 'browser', 'services', 'modified', 'note') {
      if (Has $profile $key) {
        $label = switch ($key) { 'browser' { 'Browser' } 'services' { 'AI services' } default { $labels[$key] } }
        [void]$rows.Add([pscustomobject]@{ label = $label; value = @($profile.$key) -join ', ' })
      }
    }
  }
  return , @($rows)
}

function Show-EvidenceDetail($e) {
  if ($null -eq $e -or $null -eq $script:report) { return }
  $script:ui.DetailSource.Text = [string]$e.source
  $script:ui.DetailTitle.Text = [string]$e.evidence
  $script:ui.DetailStatus.Text = $(if ($e.present -eq $true) { 'Evidence found' } elseif ($e.present -eq $false) { 'Looked for, not found' } else { 'Could not be checked' })
  $script:ui.DetailObserved.ItemsSource = Get-ObservedRows $e
  $script:ui.DetailWhy.Text = [string]$e.why
  $script:ui.DetailAbsence.Text = $(if ($e.present -ne $true -and (Has $script:report 'absence_note')) { [string]$script:report.absence_note } else { '' })
  $script:ui.DetailAbsence.Visibility = $(if ($script:ui.DetailAbsence.Text) { 'Visible' } else { 'Collapsed' })
  $script:ui.DetailDoesNotEstablish.Text = 'It reports whether a record exists and how old it is. It does not read conversation text or prove what a person said.'
  $script:ui.DetailLifetime.Visibility = $(if ($e.clock) { 'Visible' } else { 'Collapsed' })
  $script:ui.DetailClockStatus.DataContext = $e.clock.status
  $script:ui.DetailClockHeadline.Text = [string]$e.clock.headline
  $script:ui.DetailClockDeadline.Text = $(if ($e.clock.deadline) { Format-UiDate $e.clock.deadline } else { '' })
  $script:ui.DetailClockDetail.Text = [string]$e.clock.detail
  $script:ui.DetailAction.Text = [string]$e.action
  $script:ui.DetailSources.ItemsSource = @(@($e.source) + @($e.also_sources) | Where-Object { $_ })
  $script:ui.DetailCompleted.Text = [string]$script:report.generated_local
  $script:ui.DetailSettings.Text = Get-RunSettingsLine $script:report
  $script:ui.DetailPartial.Visibility = $(if ($script:report.summary.partial_checks -gt 0) { 'Visible' } else { 'Collapsed' })
  $script:ui.DetailProblems.ItemsSource = ConvertTo-List $script:report.problems
  $script:ui.ResultsOverview.Visibility = 'Collapsed'
  $script:ui.EvidenceDetailView.Visibility = 'Visible'
  $script:ui.DetailScroll.ScrollToTop()
  [void]$script:ui.BackToResultsButton.Focus()
}

function Close-EvidenceDetail {
  $script:ui.EvidenceDetailView.Visibility = 'Collapsed'
  $script:ui.ResultsOverview.Visibility = 'Visible'
  if ($script:detailOrigin) { [void]$script:detailOrigin.Focus() }
  $script:detailOrigin = $null
}

function Show-Error([string]$message) {
  $script:ui.ErrorText.Text = $message
  if ($script:ui.ReportPathText) {
    $where = @()
    foreach ($k in 'html', 'json') { if ($script:paths[$k] -and (Test-Path -LiteralPath $script:paths[$k])) { $where += "$($k.ToUpper()): $($script:paths[$k])" } }
    $script:ui.ReportPathText.Text = $(if ($where.Count) { $where -join "`n" } else { "No report was written. Report folder: $OutDir" })
  }
  Set-State 'Error' 'The check did not finish'
}

# Dates in the window are English and Gregorian whatever the Windows calendar: Thai Windows would otherwise write the
# year as 2569 and Saudi Arabic Windows as 1448 (stress test 2026-10-18).
function Format-UiDate($value) {
  return ([datetime]$value).ToString('g', [Globalization.CultureInfo]::GetCultureInfo('en-US'))
}

function Get-RunSettingsLine($d) {
  if (-not (Has $d 'run_settings') -or -not $d.run_settings.non_default) { return '' }
  return "Made with non-default settings: $(@($d.run_settings.parameters) -join ', '). Do not treat this as a normal check of this computer."
}

function Get-SummaryText($d) {
  $lines = New-Object System.Collections.ArrayList
  [void]$lines.Add("LUMINOL Check, $($d.generated_local)")
  $settingsLine = Get-RunSettingsLine $d
  if ($settingsLine) { [void]$lines.Add($settingsLine) }
  $svc = (@($d.summary.services_seen) | ForEach-Object { $_.name }) -join ', '
  $noSvc = -not $svc
  if ($noSvc) { $svc = 'none found in the places checked' }
  [void]$lines.Add("$($d.summary.evidence_found) kind(s) of AI evidence found, $($d.summary.urgent) at risk soon. AI services seen: $svc.")
  if ((Has $d 'absence_note') -and ($noSvc -or $d.summary.not_found -gt 0 -or $d.summary.evidence_found -eq 0)) { [void]$lines.Add([string]$d.absence_note) }
  if ((Has $d 'last_access_message') -and $d.last_access_message) { [void]$lines.Add([string]$d.last_access_message) }
  if ($d.summary.partial_checks -gt 0) {
    [void]$lines.Add("$($d.summary.partial_checks) check(s) were partial. Counts and absences may be incomplete; open the full report.")
    foreach ($problem in $d.problems) { if ($problem -match 'partial|stopped after') { [void]$lines.Add([string]$problem) } }
  }
  if (@($d.actions).Count) {
    [void]$lines.Add('What to do now:')
    $i = 0
    foreach ($a in $d.actions) {
      $i++
      $by = ''
      if ((Has $a 'deadline') -and $a.deadline) { $by = " (by $(Format-UiDate $a.deadline))" }
      [void]$lines.Add("$i. $($a.tool): $($a.text)$by")
    }
  }
  [void]$lines.Add("Measured lifetimes: $($d.lab_note)")
  if ((Has $d 'hold_notice') -and $d.hold_notice -and $d.hold_notice.text) { [void]$lines.Add(''); [void]$lines.Add([string]$d.hold_notice.text); [void]$lines.Add('') }
  if ($script:paths.html) { [void]$lines.Add("Full report: $($script:paths.html)") }
  return ($lines -join "`r`n")
}

# ------------------------------------------------------------------------------------------------ running the check
function New-CheckRun {
  $sync = [hashtable]::Synchronized(@{ step = 'Starting'; percent = 0 })
  $iss = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
  $iss.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass
  $rs = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
  $rs.Open()
  $ps = [PowerShell]::Create()
  $ps.Runspace = $rs
  [void]$ps.AddCommand($checkPath).AddParameter('NoOpen', $true).AddParameter('OutDir', $OutDir).AddParameter('ProgressSink', $sync)
  if ($ProfileRoot) { [void]$ps.AddParameter('ProfileRoot', $ProfileRoot) }
  if ($Now) { [void]$ps.AddParameter('Now', $Now) }
  if ($null -ne $BrowserProcessesForTest) { [void]$ps.AddParameter('BrowserProcessesForTest', $BrowserProcessesForTest) }
  return @{ ps = $ps; rs = $rs; sync = $sync; handle = $ps.BeginInvoke() }
}

# Returns @{ ok; message; json } after the run finished. Never throws.
function Complete-CheckRun($run) {
  $out = @{ ok = $false; message = ''; json = $null }
  try {
    [void]$run.ps.EndInvoke($run.handle)
    $errs = @($run.ps.Streams.Error | ForEach-Object { $_.ToString() })
    if ($run.sync['error']) { $out.message = [string]$run.sync['error'] }
    elseif (-not $run.sync['done']) { $out.message = 'The check stopped before writing its report.' + $(if ($errs.Count) { ' ' + ($errs -join ' ') } else { '' }) }
    else {
      $script:paths.html = $run.sync['html']; $script:paths.json = $run.sync['json']
      $out.json = [IO.File]::ReadAllText($run.sync['json'], [Text.Encoding]::UTF8)
      $out.ok = $true
    }
  } catch {
    $out.message = "The check failed: $($_.Exception.Message)"
    if ($run.sync['html']) { $script:paths.html = $run.sync['html']; $script:paths.json = $run.sync['json'] }
  } finally {
    $run.ps.Dispose(); $run.rs.Dispose()
  }
  return $out
}

function Start-Check {
  if ($script:run -or $script:sealRun) { return }
  $script:browserWarning = Get-BrowserWarning
  if ($script:browserWarning) {
    $script:ui.StatusText.Text = $script:browserWarning
    if (-not (Confirm-BrowserOpen $script:browserWarning)) { return }
  }
  $script:sealed = $false
  $script:report = $null
  $script:paths = @{ html = $null; json = $null }
  Set-State 'Running' 'Starting the check...'
  try { $script:run = New-CheckRun } catch { Show-Error "Could not start the check: $($_.Exception.Message)"; return }
  $timer = New-Object Windows.Threading.DispatcherTimer
  $timer.Interval = [TimeSpan]::FromMilliseconds(250)
  $timer.Add_Tick({
    $r = $script:run
    if ($null -eq $r) { $this.Stop(); return }
    $script:ui.ProgressBar.Value = [double]$r.sync['percent']
    $script:ui.StatusText.Text = [string]$r.sync['step']
    if (-not $r.handle.IsCompleted) { return }
    $this.Stop()
    $res = Complete-CheckRun $r
    $script:run = $null
    if (-not $res.ok) { Show-Error $res.message; return }
    try { Show-Report (ConvertTo-ViewModel $res.json) } catch { Show-Error "The report was written but could not be shown: $($_.Exception.Message)" }
  })
  $timer.Start()
}

# ------------------------------------------------------------------------------------------------ timestamp (opt-in)
function New-SealRun {
  $sync = [hashtable]::Synchronized(@{})
  $iss = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
  $iss.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass
  $rs = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
  $rs.Open()
  $ps = [PowerShell]::Create()
  $ps.Runspace = $rs
  [void]$ps.AddScript({
    param($sealScript, $files, $cals, $sync)
    . $sealScript
    $a = @{ Files = $files }
    if (@($cals).Count) { $a.Calendars = $cals }
    $r = New-LuminolSeal @a
    $sync.result = $r
  }).AddArgument($sealPath).AddArgument(@($script:paths.html, $script:paths.json)).AddArgument($Calendars).AddArgument($sync)
  return @{ ps = $ps; rs = $rs; sync = $sync; handle = $ps.BeginInvoke() }
}

function Complete-SealRun($run) {
  $text = ''
  try {
    [void]$run.ps.EndInvoke($run.handle)
    $r = $run.sync.result
    if ($null -eq $r) { $text = 'Timestamp failed: ' + ((@($run.ps.Streams.Error) | ForEach-Object { $_.ToString() }) -join ' ') }
    elseif (@($r.proofs).Count -gt 0) {
      $script:sealed = $true
      $text = "Pending proof saved from $(@($r.proofs).Count) calendar(s) next to the report ($([IO.Path]::GetFileName($r.seal)).ots). The request body sent a 32-byte fingerprint; calendars received connection metadata."
    } else { $text = 'Timestamp failed (offline?). The report itself is complete. ' + (@($r.errors) -join '; ') }
  } catch {
    $text = "Timestamp failed: $($_.Exception.Message)"
  } finally { $run.ps.Dispose(); $run.rs.Dispose() }
  return $text
}

function Start-Timestamp {
  if ($script:sealRun -or -not $script:paths.html) { return }
  $script:ui.TimestampButton.IsEnabled = $false
  $script:ui.TimestampText.Text = 'Timestamping: sending one report fingerprint...'
  $script:sealRun = New-SealRun
  $t = New-Object Windows.Threading.DispatcherTimer
  $t.Interval = [TimeSpan]::FromMilliseconds(250)
  $t.Add_Tick({
    $r = $script:sealRun
    if ($null -eq $r) { $this.Stop(); return }
    if (-not $r.handle.IsCompleted) { return }
    $this.Stop()
    $msg = Complete-SealRun $r
    $script:sealRun = $null
    $script:ui.TimestampText.Text = $msg
    $script:ui.TimestampButton.IsEnabled = (-not $script:sealed)
  })
  $t.Start()
}

# ------------------------------------------------------------------------------------------------ self-test
function Invoke-SelfTest {
  Initialize-Window
  $script:browserWarning = Get-BrowserWarning
  $run = New-CheckRun
  $seen = New-Object System.Collections.ArrayList
  while (-not $run.handle.IsCompleted) { $p = $run.sync['percent']; if ($p -and -not $seen.Contains($p)) { [void]$seen.Add($p) }; Start-Sleep -Milliseconds 20 }
  $res = Complete-CheckRun $run
  if ($res.ok) { Show-Report (ConvertTo-ViewModel $res.json) } else { Show-Error $res.message }
  $timestampShown = ''
  if ($SelfTestTimestamp -and $res.ok) {
    $tsEnabledBefore = [bool]$script:ui.TimestampButton.IsEnabled
    $sr = New-SealRun
    while (-not $sr.handle.IsCompleted) { Start-Sleep -Milliseconds 20 }
    $timestampShown = Complete-SealRun $sr
    $script:ui.TimestampText.Text = $timestampShown
    $script:ui.TimestampButton.IsEnabled = (-not $script:sealed)   # same as after a real click
  }
  $content = $script:window.Content
  $w = 1200; $h = 820
  $content.Measure((New-Object Windows.Size $w, $h)); $content.Arrange((New-Object Windows.Rect 0, 0, $w, $h)); $content.UpdateLayout()
  $script:window.Dispatcher.Invoke([Action]{ }, [Windows.Threading.DispatcherPriority]::ApplicationIdle)
  $groups = 0
  $groups = @($script:ui.EvidenceList.Items | ForEach-Object { [string]$_.tool } | Sort-Object -Unique).Count   # distinct tools shown
  $details = @()
  if ($res.ok) {
    foreach ($e in $script:report.evidence) {
      Show-EvidenceDetail $e
      $details += [ordered]@{
        id = $e.id; source = $script:ui.DetailSource.Text; title = $script:ui.DetailTitle.Text
        status = $script:ui.DetailStatus.Text; observed = @($script:ui.DetailObserved.ItemsSource)
        why = $script:ui.DetailWhy.Text; absence = $script:ui.DetailAbsence.Text; limit = $script:ui.DetailDoesNotEstablish.Text
        headline = $script:ui.DetailClockHeadline.Text; detail = $script:ui.DetailClockDetail.Text; action = $script:ui.DetailAction.Text
        sources = @($script:ui.DetailSources.ItemsSource); completed = $script:ui.DetailCompleted.Text
        settings = $script:ui.DetailSettings.Text; partial = [string]$script:ui.DetailPartial.Visibility; problems = @($script:ui.DetailProblems.ItemsSource)
        visible = [string]$script:ui.EvidenceDetailView.Visibility
      }
    }
    Close-EvidenceDetail
  }
  $shown = [ordered]@{
    contract = @($Contract.Keys); details = $details; detail_closed = ($script:ui.EvidenceDetailView.Visibility -eq 'Collapsed')
    ok = $res.ok; message = $res.message; tag = [string]$script:window.Tag; status = $script:ui.StatusText.Text
    browser_warning = $script:browserWarning
    check_button = [string]$script:ui.CheckButton.Content
    summary = [ordered]@{ evidence = $script:ui.SummaryEvidence.Text; urgent = $script:ui.SummaryUrgent.Text; services = $script:ui.SummaryServices.Text; could_not_check = $script:ui.SummaryCouldNotCheck.Text }
    absence_note_shown = $script:ui.SummaryAbsenceNote.Text
    run_settings_shown = $script:ui.RunSettingsText.Text
    actions = $script:ui.ActionsList.Items.Count; evidence = $script:ui.EvidenceList.Items.Count; evidence_groups = $groups
    cannot_answer = $script:ui.CannotAnswerList.Items.Count; sources = $script:ui.SourcesList.Items.Count
    privacy = $script:ui.PrivacyText.Text; error_text = $script:ui.ErrorText.Text
    buttons = [ordered]@{ open_report = $script:ui.OpenReportButton.IsEnabled; open_folder = $script:ui.OpenFolderButton.IsEnabled; copy = $script:ui.CopySummaryButton.IsEnabled; preserve = $script:ui.PreserveButton.IsEnabled }
    progress_seen = @($seen); report_json = $script:paths.json
    timestamp_button_enabled = $(if ($script:ui.TimestampButton) { [bool]$script:ui.TimestampButton.IsEnabled } else { $null })
    timestamp_text = $(if ($script:ui.TimestampText) { $script:ui.TimestampText.Text } else { '' })
    timestamp_sealed = $script:sealed
    hold_notice_shown = $(if ($script:ui.HoldNoticeText) { $script:ui.HoldNoticeText.Text } else { $null })
    copy_notice_enabled = $(if ($script:ui.CopyNoticeButton) { [bool]$script:ui.CopyNoticeButton.IsEnabled } else { $null })
    summary_text = $(if ($script:report) { Get-SummaryText $script:report } else { '' })
    first_action_deadline_kind = $(if ($script:report -and @($script:report.actions).Count -and $script:report.actions[0].deadline -is [datetime]) { [string]$script:report.actions[0].deadline.Kind } else { '' })
  }
  if ($SelfTestShot) {
    foreach ($tab in 0, 1) {
      if ($script:ui.ResultsTabs) { $script:ui.ResultsTabs.SelectedIndex = $tab }
      $content.Measure((New-Object Windows.Size $w, $h)); $content.Arrange((New-Object Windows.Rect 0, 0, $w, $h)); $content.UpdateLayout()
      $script:window.Dispatcher.Invoke([Action]{ }, [Windows.Threading.DispatcherPriority]::ApplicationIdle)
      $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap $w, $h, 96, 96, ([Windows.Media.PixelFormats]::Pbgra32)
      $bmp.Render($content)
      $png = New-Object Windows.Media.Imaging.PngBitmapEncoder
      $png.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
      $f = [IO.File]::Create(($SelfTestShot -replace '\.png$', "-$tab.png")); try { $png.Save($f) } finally { $f.Dispose() }
    }
  }
  $json = $shown | ConvertTo-Json -Depth 6
  if ($SelfTestOut) { [void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $SelfTestOut)); [IO.File]::WriteAllText($SelfTestOut, $json, (New-Object Text.UTF8Encoding($false))) } else { $json }
  $script:window.Close()
}

# ------------------------------------------------------------------------------------------------ main
if ($SelfTest) { Invoke-SelfTest; return }
try {
  if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') { throw 'needs -STA' }
  Initialize-Window
} catch {
  Start-PlainCheck $_.Exception.Message
  return
}
[void]$script:window.ShowDialog()
