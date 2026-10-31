"""The real LUMINOL window, clicked through Windows UI Automation (the interface screen readers use).

This is the only test of the live path: the visible window, the background run, the progress timer and the button
states after a real click. It opens a window on screen for a few seconds. Needs an interactive Windows session.
"""
import json
import os
import subprocess

import pytest

import test_check as tc

ROOT = tc.ROOT

DRIVER = r"""
param([string]$App, [string]$Profile, [string]$Out, [string]$Now)
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -AssemblyName System.Drawing
$AE = [Windows.Automation.AutomationElement]
function ById($el, $id) { $el.FindFirst([Windows.Automation.TreeScope]::Descendants, (New-Object Windows.Automation.PropertyCondition($AE::AutomationIdProperty, $id))) }
function EnabledIfVisible($el, $id) { $control = ById $el $id; if ($control) { return $control.Current.IsEnabled }; return $false }
$p = Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-STA','-File',"`"$App`"",'-OutDir',"`"$Out`"",'-ProfileRoot',"`"$Profile`"",'-Now',$Now,'-BrowserProcessesForTest','none') -PassThru
$r = [ordered]@{ window = $false }
$win = $null
for ($i = 0; $i -lt 60 -and -not $win; $i++) { Start-Sleep -Milliseconds 500; $win = $AE::RootElement.FindFirst([Windows.Automation.TreeScope]::Children, (New-Object Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $p.Id))) }
if ($win) {
  $r.window = $true
  $r.title = $win.Current.Name
  $r.desktop_window = @{ width = $win.Current.BoundingRectangle.Width; height = $win.Current.BoundingRectangle.Height }
  $r.before_report_enabled = EnabledIfVisible $win 'OpenReportButton'
  (ById $win 'CheckButton').GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
  $t0 = Get-Date; $seen = @()
  do { Start-Sleep -Milliseconds 150; $s = (ById $win 'StatusText').Current.Name; if ($seen -notcontains $s) { $seen += $s } } while ($s -notmatch '^Done|did not finish' -and ((Get-Date) - $t0).TotalSeconds -lt 90)
  $r.statuses = $seen
  $r.summary = @{}
  # The results tab is laid out just after the status changes: wait for it.
  for ($k = 0; $k -lt 20; $k++) { if (ById $win 'SummaryEvidence') { break }; Start-Sleep -Milliseconds 250 }
  foreach ($id in 'SummaryEvidence','SummaryUrgent','SummaryServices','SummaryCouldNotCheck') { $e = ById $win $id; $r.summary[$id] = $(if ($e) { $e.Current.Name } else { $null }) }
  $r.check_button = (ById $win 'CheckButton').Current.Name
  $r.enabled = [ordered]@{ report = (ById $win 'OpenReportButton').Current.IsEnabled; folder = (ById $win 'OpenFolderButton').Current.IsEnabled; copy = (ById $win 'CopySummaryButton').Current.IsEnabled; preserve = (EnabledIfVisible $win 'PreserveButton') }
  # 1366x768 at 150% exposes approximately 911x512 device-independent pixels.
  # Resize at the current desktop DPI so the user's display settings remain untouched.
  $transform = $win.GetCurrentPattern([Windows.Automation.TransformPattern]::Pattern)
  $transform.Move(0, 0)
  $transform.Resize(911, 512)
  Start-Sleep -Milliseconds 400
  $r.compact_window = [ordered]@{ width = $win.Current.BoundingRectangle.Width; height = $win.Current.BoundingRectangle.Height }
  $tabs = ById $win 'ResultsTabs'
  $tabCondition = New-Object Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [Windows.Automation.ControlType]::TabItem)
  $tabItems = $tabs.FindAll([Windows.Automation.TreeScope]::Children, $tabCondition)
  $r.compact_tabs = @()
  $r.details = @()
  for ($i = 0; $i -lt $tabItems.Count; $i++) {
    $tab = $tabItems.Item($i)
    $tab.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Start-Sleep -Milliseconds 100
    $rect = $tab.Current.BoundingRectangle
    $wr = $win.Current.BoundingRectangle
    $r.compact_tabs += [ordered]@{ name = $tab.Current.Name; selected = $tab.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected; visible = (-not $tab.Current.IsOffscreen); inside = ($rect.Left -ge $wr.Left -and $rect.Right -le $wr.Right -and $rect.Top -ge $wr.Top -and $rect.Bottom -le $wr.Bottom) }
    $bitmap = New-Object Drawing.Bitmap([int]$wr.Width, [int]$wr.Height)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
      $graphics.CopyFromScreen([int]$wr.Left, [int]$wr.Top, 0, 0, $bitmap.Size)
      $bitmap.Save((Join-Path (Split-Path -Parent $Out) ("compact-$i.png")), [Drawing.Imaging.ImageFormat]::Png)
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
    if ($i -eq 1) {
      $report = Get-Content -LiteralPath (Get-ChildItem -LiteralPath $Out -Filter '*.json' | Select-Object -First 1).FullName -Raw | ConvertFrom-Json
      foreach ($finding in @($report.evidence | Select-Object -First 1) + @($report.evidence | Where-Object { $_.present -ne $true } | Select-Object -First 1)) {
        $choice = ById $win $finding.id
        $choice.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
        Start-Sleep -Milliseconds 200
        $shown = [ordered]@{ id = $finding.id; title = (ById $win 'DetailTitle').Current.Name; source = (ById $win 'DetailSource').Current.Name; status = (ById $win 'DetailStatus').Current.Name; limit = (ById $win 'DetailDoesNotEstablish').Current.Name }
        $scroller = ById $win 'DetailScroll'
        $scroll = $scroller.GetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern)
        if ($scroll.Current.VerticallyScrollable) { $scroll.SetScrollPercent(-1, 100) }
        Start-Sleep -Milliseconds 150
        $action = ById $win 'DetailAction'
        $shown.action = $action.Current.Name
        $shown.action_visible = -not $action.Current.IsOffscreen
        (ById $win 'BackToResultsButton').GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
        Start-Sleep -Milliseconds 150
        # WPF keeps a collapsed button in the automation tree, marked off-screen: back on the list means the finding's
        # own button is there again and the Back button is hidden.
        $back = ById $win 'BackToResultsButton'
        $shown.returned = ($null -ne (ById $win $finding.id)) -and ((-not $back) -or $back.Current.IsOffscreen)
        $shown.focus_returned = (ById $win $finding.id).Current.HasKeyboardFocus
        $r.details += $shown
      }
    }
  }
  $r.compact_footer_inside = $true
  foreach ($id in 'OpenReportButton','OpenFolderButton','CopySummaryButton') {
    $rect = (ById $win $id).Current.BoundingRectangle
    $wr = $win.Current.BoundingRectangle
    if ($rect.Left -lt $wr.Left -or $rect.Right -gt $wr.Right -or $rect.Top -lt $wr.Top -or $rect.Bottom -gt $wr.Bottom) { $r.compact_footer_inside = $false }
  }
  $win.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close()
  Start-Sleep -Seconds 2
}
if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force; $r.killed = $true } else { $r.killed = $false }
$r | ConvertTo-Json -Depth 5
"""


@pytest.fixture(scope="module")
def live(tmp_path_factory):
    profile = tc.profile.__wrapped__(tmp_path_factory)
    work = tmp_path_factory.mktemp("live")
    driver = work / "drive.ps1"
    driver.write_text(DRIVER, encoding="utf-8")
    out = work / "out"
    p = subprocess.run(["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(driver),
                        "-App", os.path.join(ROOT, "src", "Luminol-App.ps1"), "-Profile", profile, "-Out", str(out),
                        "-Now", tc.NOW.isoformat()], capture_output=True, text=True, timeout=240)
    assert p.returncode == 0, p.stderr
    return json.loads(p.stdout), out


def test_window_opens_and_finishes_after_a_click(live):
    r, out = live
    assert r["window"] and r["title"] == "LUMINOL"
    assert r["before_report_enabled"] is False
    assert r["statuses"][-1].startswith("Done"), r["statuses"]
    assert any(s.startswith("Checking:") for s in r["statuses"]), "real progress steps shown"
    assert r["check_button"] == "Check again"
    assert r["enabled"] == {"report": True, "folder": True, "copy": True, "preserve": False}
    assert r["killed"] is False, "closing the window ends the app"


def test_window_numbers_match_the_report(live):
    r, out = live
    js = [f for f in os.listdir(out) if f.endswith(".json")]
    assert len(js) == 1
    d = json.load(open(os.path.join(out, js[0]), encoding="utf-8"))
    assert r["summary"]["SummaryEvidence"] == str(d["summary"]["evidence_found"])
    assert r["summary"]["SummaryUrgent"] == str(d["summary"]["urgent"])
    assert r["summary"]["SummaryServices"] == str(len(d["summary"]["services_seen"]))


def test_compact_window_all_tabs_and_footer_reachable(live):
    r, _ = live
    assert abs(r["compact_window"]["width"] - 911) <= 10
    assert abs(r["compact_window"]["height"] - 512) <= 20
    assert [tab["name"] for tab in r["compact_tabs"]] == ["Overview", "Evidence", "Sources & limits", "Draft notice"]
    assert all(tab["selected"] and tab["visible"] and tab["inside"] for tab in r["compact_tabs"]), r["compact_tabs"]
    assert r["compact_footer_inside"] is True


def test_detail_click_scroll_and_back_in_live_window(live):
    r, out = live
    report = json.loads(next(out.glob("*.json")).read_text(encoding="utf-8-sig"))
    assert r["details"]
    for shown in r["details"]:
        item = next(e for e in report["evidence"] if e["id"] == shown["id"])
        assert shown["title"] == item["evidence"]
        assert shown["source"] == item["source"]
        assert shown["action"] == item["action"]
        assert shown["action_visible"] and shown["returned"] and shown["focus_returned"]
        assert shown["status"] == ("Evidence found" if item["present"] else "Looked for, not found" if item["present"] is False else "Could not be checked")
