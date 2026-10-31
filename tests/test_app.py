"""LUMINOL app window: logic tests. The window is loaded from the real ui\\MainWindow.xaml and filled off-screen.

Run: python -m pytest -q -p no:cacheprovider tests   (Windows; Python 3.8+ with pytest)
"""
import json
import os
import re
import shutil
import subprocess

import pytest

import test_check as tc

ROOT = tc.ROOT
APP = os.path.join(ROOT, "src", "Luminol-App.ps1")
CONTRACT = {
    "CheckButton": "Button", "ProgressBar": "ProgressBar", "StatusText": "TextBlock",
    "SummaryEvidence": "TextBlock", "SummaryUrgent": "TextBlock", "SummaryServices": "TextBlock",
    "SummaryCouldNotCheck": "TextBlock", "SummaryAbsenceNote": "TextBlock", "RunSettingsText": "TextBlock", "ActionsList": "ItemsControl", "EvidenceList": "ItemsControl",
    "CannotAnswerList": "ItemsControl", "SourcesList": "ItemsControl", "PrivacyText": "TextBlock",
    "OpenReportButton": "Button", "OpenFolderButton": "Button", "CopySummaryButton": "Button",
    "PreserveButton": "Button", "ErrorPanel": "Border", "ErrorText": "TextBlock",
}


def run_app(app_path, profile, out, *extra, self_test=True):
    shown = os.path.join(out, "shown.json")
    cmd = ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-STA", "-File", app_path,
           "-ProfileRoot", profile, "-OutDir", out, "-Now", tc.NOW.isoformat()] + list(extra)
    if self_test:
        cmd += ["-SelfTest", "-SelfTestOut", shown]
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    assert p.returncode == 0, p.stdout + p.stderr
    if not self_test:
        return None
    with open(shown, encoding="utf-8") as f:
        return json.load(f)


@pytest.fixture(scope="module")
def shown(tc_profile, tmp_path_factory):
    out = str(tmp_path_factory.mktemp("app"))
    return run_app(APP, tc_profile, out), out


@pytest.fixture(scope="module")
def tc_profile(tmp_path_factory):
    return tc.profile.__wrapped__(tmp_path_factory)


def report_of(shown_obj):
    with open(shown_obj["report_json"], encoding="utf-8") as f:
        return json.load(f)


def test_xaml_contract_names_and_types():
    xaml = open(os.path.join(ROOT, "src", "ui", "MainWindow.xaml"), encoding="utf-8").read()
    for name, typ in CONTRACT.items():
        assert re.search(r"<%s\b[^>]*x:Name=\"%s\"" % (typ, name), xaml), name
    assert "/*" not in xaml  # no stray template placeholders


def test_window_shows_exactly_the_report(shown):
    s, _ = shown
    d = report_of(s)
    assert s["ok"] is True and s["tag"] == "Results" and s["check_button"] == "Check again"
    assert s["summary"] == {"evidence": str(d["summary"]["evidence_found"]), "urgent": str(d["summary"]["urgent"]),
                            "services": str(len(d["summary"]["services_seen"])), "could_not_check": str(d["summary"]["could_not_check"])}
    assert s["actions"] == len(d["actions"]) and s["evidence"] == len(d["evidence"])
    assert s["cannot_answer"] == len(d["cannot_answer"]) and s["sources"] == len(d["sources"])
    assert s["evidence_groups"] == len({e["tool"] for e in d["evidence"]})
    assert s["privacy"] == d["privacy"]
    assert s["run_settings_shown"] == ("Made with non-default settings: Now, ProfileRoot. Do not treat this as a normal check of this computer.")
    assert s["run_settings_shown"] in s["summary_text"]
    assert s["first_action_deadline_kind"] == "Local"  # UTC deadlines shown in local time


def test_buttons_and_progress(shown):
    s, _ = shown
    assert s["buttons"] == {"open_report": True, "open_folder": True, "copy": True, "preserve": False}
    assert s["progress_seen"] and max(s["progress_seen"]) >= 50
    assert "- report saved" in s["status"] and not re.search(r"[^\x00-\x7f]", s["status"])


def test_browser_warning_on_existing_xaml_fallback(tc_profile, tmp_path):
    out = tmp_path / "warning"
    out.mkdir()
    s = run_app(APP, tc_profile, str(out), "-BrowserProcessesForTest", "chrome,msedge")
    assert s["ok"] is True
    assert "Chrome is open" in s["browser_warning"] and "Edge is open" in s["browser_warning"]
    assert "Close it for a complete check, or continue" in s["browser_warning"]
    assert report_of(s)["browsers_open"] == ["Chrome", "Edge"]


def test_summary_text_is_truthful(shown):
    s, _ = shown
    d = report_of(s)
    text = s["summary_text"]
    assert text.startswith("LUMINOL Check, ")
    assert "%d kind(s) of AI evidence found, %d at risk soon" % (d["summary"]["evidence_found"], d["summary"]["urgent"]) in text
    for a in d["actions"]:
        assert a["text"] in text
    assert d["lab_note"] in text  # the current lab caveat travels with the summary
    assert d["hold_notice"]["text"] in text  # draft preservation notice included
    assert tc.USER not in text


def test_empty_result_shows_absence_in_window_and_copy(tmp_path):
    profile = tmp_path / tc.USER
    profile.mkdir()
    out = tmp_path / "out"
    out.mkdir()
    shown = run_app(APP, str(profile), str(out))
    report = report_of(shown)
    assert report["summary"]["evidence_found"] == 0
    assert shown["absence_note_shown"] == report["absence_note"]
    assert "AI services seen: none found in the places checked." in shown["summary_text"]
    assert report["absence_note"] in shown["summary_text"]


def test_every_referenced_source_is_listed(shown):
    d = report_of(shown[0])
    ids = {x["id"] for x in d["sources"]}
    refs = {e["source"] for e in d["evidence"]} | {s for e in d["evidence"] for s in e.get("also_sources", [])}
    assert refs <= ids, refs - ids


def test_missing_engine_file_shows_error_not_results(tc_profile, tmp_path):
    copy = tmp_path / "src"
    shutil.copytree(os.path.join(ROOT, "src"), copy)
    os.remove(copy / "catalog.json")
    s = run_app(str(copy / "Luminol-App.ps1"), tc_profile, str(tmp_path / "out"))
    assert s["ok"] is False and s["tag"] == "Error"
    assert "catalog.json" in s["error_text"]
    assert s["buttons"]["open_report"] is False and s["buttons"]["copy"] is False


def test_broken_window_falls_back_to_plain_report(tc_profile, tmp_path):
    copy = tmp_path / "src"
    shutil.copytree(os.path.join(ROOT, "src"), copy)
    xaml = copy / "ui" / "MainWindow.xaml"
    xaml.write_text(xaml.read_text(encoding="utf-8").replace('x:Name="SummaryUrgent"', 'x:Name="Renamed"'), encoding="utf-8")
    out = tmp_path / "out"
    run_app(str(copy / "Luminol-App.ps1"), tc_profile, str(out), "-NoOpen", self_test=False)
    assert any(f.endswith(".html") for f in os.listdir(out)), "plain check must still produce the report"


def test_tab_content_reachable_by_screen_readers():
    # Without this part name, UI Automation (screen readers) cannot see the selected tab's content.
    xaml = open(os.path.join(ROOT, "src", "ui", "MainWindow.xaml"), encoding="utf-8").read()
    assert 'x:Name="PART_SelectedContentHost"' in xaml


def test_optional_notice_hooks_when_present(shown):
    s, _ = shown
    d = report_of(s)
    if s.get("hold_notice_shown") is not None:
        assert s["hold_notice_shown"] == d["hold_notice"]["text"]
    if s.get("copy_notice_enabled") is not None:
        assert s["copy_notice_enabled"] is bool(d["hold_notice"]["text"])


def test_every_finding_has_a_faithful_detail_view(shown):
    s, _ = shown
    report = report_of(s)
    assert len(s["details"]) == len(report["evidence"])
    assert s["detail_closed"] is True
    assert {"DetailObserved", "DetailPartial", "BackToResultsButton"} <= set(s["contract"])
    for detail, item in zip(s["details"], report["evidence"]):
        assert detail["visible"] == "Visible"
        assert detail["id"] == item["id"]
        assert detail["source"] == item["source"]
        assert detail["title"] == item["evidence"]
        assert detail["why"] == item["why"]
        assert detail["action"] == item["action"]
        assert detail["limit"] == "It reports whether a record exists and how old it is. It does not read conversation text or prove what a person said."
        assert detail["absence"] == (report["absence_note"] if item["present"] is not True else "")
        assert detail["completed"] == report["generated_local"]
        assert detail["sources"] == [item["source"], *item.get("also_sources", [])]
        assert detail["settings"] == s["run_settings_shown"]
        assert detail["partial"] == ("Visible" if report["summary"]["partial_checks"] else "Collapsed")
        assert detail["problems"] == report["problems"]
        for path in item["result"].get("found_locations", []):
            assert path in [row["value"] for row in detail["observed"]]
        for key, label in (("files", "Files"), ("bytes", "Bytes"), ("newest", "Newest change"), ("oldest", "Oldest change")):
            if key in item["result"].get("summary", {}):
                assert {"label": label, "value": str(item["result"]["summary"][key])} in detail["observed"]
        if item.get("clock"):
            assert detail["headline"] == item["clock"]["headline"]
            assert detail["detail"] == item["clock"]["detail"]
    assert tc.USER not in json.dumps(s["details"])
