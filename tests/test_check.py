"""LUMINOL Check against a fake user profile with known contents.

Run: python -m pytest -q -p no:cacheprovider tests   (Windows; Python 3.8+ with pytest)
Needs Windows (PowerShell 5.1, NTFS alternate data streams).
"""
import ctypes
import json
import os
import subprocess
import time
from datetime import datetime, timedelta, timezone

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "src", "Luminol-Check.ps1")
NOW = datetime(2026, 10, 13, 12, 0, 0, tzinfo=timezone.utc)
USER = "LuminolTestUserQX"  # must never appear in the report


def touch(path, data=b"x", days_ago=0.0):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)
    t = (NOW - timedelta(days=days_ago)).timestamp()
    os.utime(path, (t, t))


def zone_mark(path, text, days_ago):
    # Writing an NTFS stream changes the file's own modified time to the real clock, so the
    # fixture time is set again afterwards (the old order made this test depend on the real month).
    with open(path + ":Zone.Identifier", "w") as f:
        f.write(text)
    t = (NOW - timedelta(days=days_ago)).timestamp()
    os.utime(path, (t, t))


def run(profile, out, extra=()):
    cmd = ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", SCRIPT,
           "-ProfileRoot", profile, "-OutDir", out, "-NoOpen", "-Now", NOW.isoformat()] + list(extra)
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    assert p.returncode == 0, p.stdout + p.stderr
    js = [f for f in os.listdir(out) if f.endswith(".json")]
    html = [f for f in os.listdir(out) if f.endswith(".html")]
    assert len(js) == 1 and len(html) == 1
    with open(os.path.join(out, js[0]), encoding="utf-8") as f:
        raw = f.read()
    with open(os.path.join(out, html[0]), encoding="utf-8") as f:
        page = f.read()
    return json.loads(raw), raw, page


def item(d, item_id):
    for e in d["evidence"]:
        if e["id"] == item_id:
            return e
    raise KeyError(item_id)


@pytest.fixture(scope="module")
def profile(tmp_path_factory):
    base = tmp_path_factory.mktemp("luminol")
    prof = str(base / USER)
    L = os.path.join(prof, "AppData", "Local")
    R = os.path.join(prof, "AppData", "Roaming")
    # ChatGPT desktop / Codex
    touch(os.path.join(prof, ".codex", ".codex-global-state.json"), b"{}", 0.5)
    touch(os.path.join(prof, ".codex", ".codex-global-state.json.bak"), b"{}", 0.8)
    touch(os.path.join(L, "Codex", "Logs", "2026", "10", "12", "a.log"), b"log", 1)
    # Codex agent: session file + debug log + thread databases (names only matter)
    touch(os.path.join(prof, ".codex", "sessions", "2026", "10", "10", "rollout-x.jsonl"), b"{}", 3)
    touch(os.path.join(prof, ".codex", "archived_sessions", "rollout-old.jsonl"), b"{}", 4)
    touch(os.path.join(prof, ".codex", "logs_2.sqlite"), b"SQLite format 3\x00", 0.2)
    touch(os.path.join(prof, ".codex", "state_5.sqlite"), b"SQLite format 3\x00", 0.2)
    touch(os.path.join(prof, ".codex", "thread_history_1.sqlite"), b"SQLite format 3\x00", 0.2)
    # Claude Code: retention set to 10 days on this machine, one transcript 20 days old
    touch(os.path.join(prof, ".claude", "settings.json"), b'{"cleanupPeriodDays": 10}', 5)
    touch(os.path.join(prof, ".claude", "projects", "p1", "old.jsonl"), b"{}", 20)
    touch(os.path.join(prof, ".claude", "projects", "p1", "new.jsonl"), b"{}", 1)
    touch(os.path.join(R, "Claude", "Local Storage", "leveldb", "000003.log"), b"PRIVATE_CLAUDE_TEXT", 0.4)
    touch(os.path.join(R, "Cursor", "User", "globalStorage", "state.vscdb"), b"PRIVATE_CURSOR_TEXT", 0.4)
    for extension in ("saoudrizwan.claude-dev", "rooveterinaryinc.roo-cline", "kilocode.kilo-code"):
        touch(os.path.join(R, "Code", "User", "globalStorage", extension, "tasks", "task-1", "task.json"),
              b"PRIVATE_TASK_TEXT", 0.4)
    for path in ((prof, ".ollama", "models", "manifest"), (L, "Ollama", "server.log"),
                 (prof, ".lmstudio", "models", "model.gguf"), (prof, ".cache", "lm-studio", "model.gguf"),
                 (L, "nomic.ai", "GPT4All", "model.gguf"), (R, "Jan", "data", "threads", "thread.json"),
                 (R, "anythingllm-desktop", "storage", "thread.json")):
        touch(os.path.join(*path), b"PRIVATE_MODEL_TEXT", 0.4)
    # Chrome: history mentions chatgpt.com and gemini; claude.ai site storage changed 6 hours ago
    chrome = os.path.join(L, "Google", "Chrome", "User Data")
    touch(os.path.join(chrome, "Default", "History"), b"SQLite format 3\x00...https://chatgpt.com/c/abc...gemini.google.com/app/x", 0.1)
    touch(os.path.join(chrome, "Default", "IndexedDB", "https_claude.ai_0.indexeddb.leveldb", "000003.log"), b"x", 0.25)
    touch(os.path.join(chrome, "Default", "IndexedDB", "https_chatgpt.com_0.indexeddb.leveldb", "000003.log"),
          b"PRIVATE_WEB_TEXT", 0.25)
    # Edge profile whose history will be locked during one test
    edge = os.path.join(L, "Microsoft", "Edge", "User Data")
    touch(os.path.join(edge, "Profile 1", "History"), b"SQLite format 3\x00 perplexity.ai", 2)
    # Notifications DB mentions the ChatGPT app
    touch(os.path.join(L, "Microsoft", "Windows", "Notifications", "wpndatabase.db"), b"...OpenAI.Codex_2p2nqsd0c76g0!App...", 0)
    # Downloads: one file from chatgpt.com (Mark of the Web), one from elsewhere, one without a mark
    dl = os.path.join(prof, "Downloads")
    touch(os.path.join(dl, "report.docx"), b"doc", 3)
    zone_mark(os.path.join(dl, "report.docx"),
              "[ZoneTransfer]\nZoneId=3\nReferrerUrl=https://chatgpt.com/\nHostUrl=https://files.oaiusercontent.com/file-x\n", 3)
    touch(os.path.join(dl, "other.pdf"), b"pdf", 3)
    zone_mark(os.path.join(dl, "other.pdf"), "[ZoneTransfer]\nZoneId=3\nHostUrl=https://example.com/other.pdf\n", 3)
    touch(os.path.join(dl, "plain.txt"), b"t", 3)
    touch(os.path.join(R, "Microsoft", "Windows", "Recent", "sample.lnk"), b"PRIVATE_LINK_TEXT", 0.5)
    return prof


@pytest.fixture(scope="module")
def result(profile, tmp_path_factory):
    out = str(tmp_path_factory.mktemp("out"))
    return run(profile, out)


def test_finds_known_evidence_and_services(result):
    d, raw, page = result
    seen = {s["id"] for s in d["summary"]["services_seen"]}
    assert {"chatgpt", "gemini", "claude", "perplexity"} <= seen
    assert item(d, "chatgpt-desktop-prompt-history")["present"] is True
    assert item(d, "chatgpt-desktop-logs")["present"] is True
    assert item(d, "cursor-chat-store")["present"] is True
    assert item(d, "cloud-chatgpt")["present"] is True and item(d, "cloud-gemini")["present"] is True


def test_short_lived_clock_uses_last_change(result):
    d = result[0]
    c = item(d, "claude-web-storage")["clock"]
    assert c["status"] == "urgent"
    assert "11 hours" in c["headline"]  # earliest measured loss 0.7 days = 16.8 h, minus 6 h since last change
    assert c["deadline"] == "2026-10-13T22:48:00Z"  # changed 06:00Z + 16.8 h


def test_rolling_clock_reads_local_setting_and_reports_overdue(result):
    d = result[0]
    c = item(d, "claude-code-transcripts")["clock"]
    assert c["status"] == "urgent" and c["overdue"] == 1
    assert "10-day limit" in c["headline"] and "setting: 10 days" in c["detail"]


def test_codex_agent_stores_are_at_risk_not_stable(result):
    # Deleting a thread in the app can remove these, so "stays for now" would mislead a legal hold. No lab duration
    # is cited: the 17 Oct observation had no app version (strategy 25 Oct).
    d = result[0]
    for iid in ("codex-agent-sessions", "codex-agent-logs", "codex-agent-threads"):
        e = item(d, iid)
        assert e["present"] is True, iid
        assert e["clock"]["status"] == "urgent", iid
        assert "At risk when the thread is deleted in the app" == e["clock"]["headline"], iid
        assert "Lifetime not measured" in e["clock"]["detail"] and "17 October" not in e["clock"]["detail"], iid
    assert item(d, "codex-agent-threads")["result"]["summary"]["files"] == 2
    hn = d["hold_notice"]
    agent_lines = [i for i in hn["items"] if i["tool"] == "ChatGPT / Codex agent"]
    assert len(agent_lines) == 1 and agent_lines[0]["instruction"].count(".codex folder") == 1, "one merged line, no repeats"
    assert any(a["tool"] == "ChatGPT / Codex agent" for a in d["actions"])


def test_refreshed_lab_numbers(result):
    d = result[0]
    assert "15 days" in item(d, "chatgpt-desktop-prompt-history")["clock"]["headline"]
    logs = item(d, "chatgpt-desktop-logs")["clock"]
    assert logs["status"] == "rolling" and "14-day reference window" in logs["headline"]
    assert "one run" in logs["detail"]
    assert any("administrator" in x for x in d["cannot_answer"])
    # Strategy 25 Oct: the unversioned 17 Oct Codex deletion is never cited; those stores stay at risk.
    assert "LAB-CODEX-DELETE" not in {s["id"] for s in d["sources"]}
    assert item(d, "codex-agent-sessions")["clock"]["status"] == "urgent"


def test_downloads_counted_by_mark_of_the_web(result):
    r = item(result[0], "ai-downloads")["result"]
    assert r["files"] == 1 and r["files_checked"] == 3
    by = r["by_service"] if isinstance(r["by_service"], list) else [r["by_service"]]
    assert by[0]["service"] == "chatgpt"


def test_notifications_and_history_names(result):
    d = result[0]
    assert "OpenAI.Codex" in item(d, "ai-notifications")["result"]["names"]
    profiles = item(d, "browser-history")["result"]["profiles"]
    chrome = [p for p in profiles if p["browser"] == "Chrome"][0]
    assert set(chrome["services"]) == {"ChatGPT", "Gemini"}


def test_privacy_no_user_name_and_no_content(result):
    d, raw, page = result
    assert d["last_access_message"] in d["privacy"]
    assert d["last_access_updates"]["enabled"] in (True, False, None)
    assert "did not change anything" not in d["privacy"]
    assert USER not in raw and USER not in page
    assert "abc" not in raw  # no URL paths or text from inside files, only site names
    assert "%USERPROFILE%" in raw
    for secret in ("PRIVATE_CLAUDE_TEXT", "PRIVATE_CURSOR_TEXT", "PRIVATE_TASK_TEXT",
                   "PRIVATE_MODEL_TEXT", "PRIVATE_WEB_TEXT", "PRIVATE_LINK_TEXT"):
        assert secret not in raw and secret not in page


@pytest.mark.parametrize("raw,enabled,managed,message", [
    ("0", True, False, "records when files are last opened"),
    ("2147483650", True, True, "records when files are last opened"),
    ("1", False, False, "does not record when files are last opened"),
    ("unknown", None, None, "could not tell whether Windows records"),
    ("not-an-integer", None, None, "could not tell whether Windows records"),
    ("999999999999999999999999999999", None, None, "could not tell whether Windows records"),
])
def test_last_access_setting_branches(profile, tmp_path, raw, enabled, managed, message):
    d, _, page = run(profile, str(tmp_path / "report"), ("-LastAccessRawForTest", raw))
    expected_raw = int(raw) if raw.isdecimal() and len(raw) < 19 else None
    assert d["last_access_updates"] == {"raw": expected_raw,
                                         "enabled": enabled, "system_managed": managed}
    assert message in d["last_access_message"]
    assert d["last_access_message"] in d["privacy"]
    assert message in page


def test_report_page_has_data_and_sources(result):
    d, raw, page = result
    assert "/*__LUMINOL_DATA__*/null" not in page
    ids = {s["id"] for s in d["sources"]}
    assert {"LAB-EXP003", "CLAUDE-CODE", "OPENAI-RETENTION", "WIN-MOTW"} <= ids
    assert d["actions"][-1]["tool"] == "Legal hold"


def test_locked_history_is_reported_not_guessed(profile, tmp_path):
    hist = os.path.join(profile, "AppData", "Local", "Microsoft", "Edge", "User Data", "Profile 1", "History")
    k32 = ctypes.windll.kernel32
    k32.CreateFileW.restype = ctypes.c_void_p
    GENERIC_READ, OPEN_EXISTING = 0x80000000, 3
    h = k32.CreateFileW(hist, GENERIC_READ, 0, None, OPEN_EXISTING, 0, None)  # share mode 0 = exclusive
    assert h not in (None, ctypes.c_void_p(-1).value)
    try:
        d = run(profile, str(tmp_path))[0]
    finally:
        k32.CloseHandle(ctypes.c_void_p(h))
    edge = [p for p in item(d, "browser-history")["result"]["profiles"] if p["browser"] == "Edge"][0]
    assert edge["readable"] is False
    assert any("could not be read" in p for p in d["problems"])


def test_hold_notice_names_what_was_found(result):
    d, raw, page = result
    hn = d["hold_notice"]
    tools = {i["tool"] for i in hn["items"]}
    found_tools = {e["tool"] for e in d["evidence"] if e["present"] is True}
    assert tools <= found_tools and "ChatGPT desktop app" in tools and "Claude Code" in tools
    assert "Cursor" in hn["text"]
    assert hn["text"].startswith("AI PRESERVATION NOTICE - DRAFT FOR COUNSEL TO ADAPT")
    assert "a draft for your counsel to adapt" in hn["text"] and "other devices" in hn["text"]
    assert USER not in hn["text"]
    assert len({i["tool"] for i in hn["items"]}) == len(hn["items"]), "one line per tool"


def test_hold_notice_warns_about_automatic_deletion_with_sourced_clocks(result, empty_result):
    notice = result[0]["hold_notice"]["text"]
    assert "ChatGPT desktop app - App log files:" in notice
    assert "(Lab measurement)." in notice
    assert "(Vendor policy)." in notice
    assert "(System design)." in notice
    assert "A preservation notice cannot stop automatic deletion: collect these items promptly." in notice
    assert "Cursor - Cursor chat store:" not in notice  # NOT-MEASURED is excluded
    assert empty_result[0]["hold_notice"]["text"] is None
    assert "A preservation notice" in result[2]  # complete report embeds the notice


def test_browser_process_warning_names_only(profile, tmp_path):
    cmd = ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", SCRIPT,
           "-ProfileRoot", profile, "-OutDir", str(tmp_path), "-NoOpen", "-Now", NOW.isoformat(),
           "-BrowserProcessesForTest", "chrome,firefox,not-a-browser"]
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    assert p.returncode == 0, p.stdout + p.stderr
    # PowerShell receives a single comma-delimited argument here; the test hook must split it.
    assert "Chrome is open" in p.stdout and "Firefox is open" in p.stdout
    assert "not-a-browser" not in p.stdout
    report = json.loads(next(tmp_path.glob("*.json")).read_text(encoding="utf-8"))
    assert report["browsers_open"] == ["Chrome", "Firefox"]


# Each listed ID is an explicit positive/negative contract. A catalogue addition must
# add fixtures and a new entry here; parametrization alone would silently accept it.
CATALOGUE_IDS = (
    "chatgpt-desktop-prompt-history", "chatgpt-desktop-logs", "codex-agent-sessions",
    "codex-agent-logs", "codex-agent-threads", "claude-desktop-data",
    "claude-code-transcripts", "cursor-chat-store", "vscode-agent-tasks",
    "local-ai-models", "browser-history", "claude-web-storage",
    "chatgpt-web-storage", "ai-notifications", "ai-downloads", "recent-files",
    "cloud-chatgpt", "cloud-claude", "cloud-gemini",
)


@pytest.fixture(scope="module")
def empty_result(tmp_path_factory):
    base = tmp_path_factory.mktemp("empty-profile")
    prof = str(base / USER)
    os.makedirs(prof)
    return run(prof, str(tmp_path_factory.mktemp("empty-out")))


def test_absence_contract_is_owned_by_check(empty_result):
    d = empty_result[0]
    assert d["summary"]["evidence_found"] == 0
    assert d["absence_note"] == (
        "Not found does not mean AI was not used. Cleared browser history, private "
        "(InPrivate or Incognito) windows, another browser or Windows account, a phone "
        "or another computer leave nothing here for LUMINOL to find, and LUMINOL "
        "cannot tell whether history was cleared."
    )
    assert d["cannot_answer"][0] == (
        "Whether browser history or files were cleared or deleted before this check. "
        "A cleared history looks the same to LUMINOL as one with no AI visits. "
        "A forensic triage can look for signs of clearing."
    )
    assert item(d, "browser-history")["result"]["note"] == (
        "No listed AI site in the history files that were read. History the user "
        "cleared, and private windows, leave no entry here."
    )


def test_catalogue_coverage_guard():
    with open(os.path.join(ROOT, "src", "catalog.json"), encoding="utf-8") as f:
        catalogue = json.load(f)
    assert {x["id"] for x in catalogue["items"]} == set(CATALOGUE_IDS)
    assert len(CATALOGUE_IDS) == len(set(CATALOGUE_IDS)) == 19


@pytest.mark.parametrize("iid", CATALOGUE_IDS)
def test_catalogue_positive(iid, result):
    d, raw, page = result
    with open(os.path.join(ROOT, "src", "catalog.json"), encoding="utf-8") as f:
        spec = next(x for x in json.load(f)["items"] if x["id"] == iid)
    e = item(d, iid)
    assert e["present"] is True, iid
    assert e["service"] == spec["service"] and e["tool"] == spec["tool"]
    assert e["clock"] and e["clock"]["status"] != "unknown" or spec["clock"]["type"] == "unknown"
    r = e["result"]
    if spec["detect"]["kind"] == "files":
        assert r["summary"]["files"] >= 1
        assert r["summary"]["newest"].startswith("2026-10-")
        assert set(r["locations"]) <= set(spec["detect"]["paths"])
        assert r["found_locations"]
    elif spec["detect"]["kind"] == "site_storage":
        assert r["summary"]["files"] >= 1 and r["summary"]["newest"].startswith("2026-10-")
    elif iid == "browser-history":
        assert any("ChatGPT" in p.get("services", []) for p in r["profiles"])
    elif iid == "ai-notifications":
        assert r["names"] and r["modified"].startswith("2026-10-")
    elif iid == "ai-downloads":
        assert r["files"] == 1 and r["newest"] == "2026-10-10T12:00:00Z"  # the fixture time, not the real clock
    else:
        assert r["seen_in"], iid
    assert USER not in raw and USER not in page


@pytest.mark.parametrize("iid", CATALOGUE_IDS)
def test_catalogue_negative(iid, empty_result):
    d, raw, page = empty_result
    e = item(d, iid)
    if iid == "ai-notifications":
        assert e["present"] is None and "could not be read" in e["result"]["note"]
    else:
        assert e["present"] is False, iid
    assert e["clock"] is None
    assert USER not in raw and USER not in page


CHATGPT_OLD_LOG = ("AppData", "Local", "Codex", "Logs", "2026", "10", "12", "old.log")
CHATGPT_PACKAGE_LOG = ("AppData", "Local", "Packages", "OpenAI.Codex_abc", "LocalCache",
                       "Local", "Codex", "Logs", "2026", "10", "12", "package.log")


@pytest.mark.parametrize("layout", ["old", "package", "both"])
def test_chatgpt_desktop_log_layouts(layout, tmp_path):
    prof = str(tmp_path / USER)
    os.makedirs(prof)
    if layout in ("old", "both"):
        touch(os.path.join(prof, *CHATGPT_OLD_LOG), b"PRIVATE_LOG_TEXT", 3)
    if layout in ("package", "both"):
        touch(os.path.join(prof, *CHATGPT_PACKAGE_LOG), b"PRIVATE_LOG_TEXT", 1)
    # A sibling package with the same leaf name must not satisfy OpenAI.Codex_*.
    touch(os.path.join(prof, "AppData", "Local", "Packages", "Other.App_abc", "LocalCache",
                       "Local", "Codex", "Logs", "decoy.log"), b"PRIVATE_DECOY_TEXT", 0)
    d, raw, page = run(prof, str(tmp_path / "out"))
    matches = [e for e in d["evidence"] if e["id"] == "chatgpt-desktop-logs"]
    assert len(matches) == 1 and matches[0]["present"] is True
    r = matches[0]["result"]
    assert r["summary"]["files"] == (2 if layout == "both" else 1)
    assert r["summary"]["newest"] == ("2026-10-12T12:00:00Z" if layout != "old" else "2026-10-10T12:00:00Z")
    expected = set()
    if layout in ("old", "both"):
        expected.add(r"%LOCALAPPDATA%\Codex\Logs")
    if layout in ("package", "both"):
        expected.add(r"%LOCALAPPDATA%\Packages\OpenAI.Codex_abc\LocalCache\Local\Codex\Logs")
    assert set(r["found_locations"]) == expected
    assert USER not in raw and USER not in page
    assert "PRIVATE_LOG_TEXT" not in raw + page and "PRIVATE_DECOY_TEXT" not in raw + page


CLAUDE_DESKTOP_LAYOUTS = {
    "old": (("AppData", "Roaming", "Claude", "Local Storage", "leveldb", "old.log"),
            r"%APPDATA%\Claude"),
    "claude_data": (("AppData", "Local", "Claude-Data", "claude_abc", "Local Storage", "leveldb", "data.log"),
                    r"%LOCALAPPDATA%\Claude-Data\claude_abc"),
    "logs": (("AppData", "Local", "Claude", "logs", "app.log"), r"%LOCALAPPDATA%\Claude\logs"),
    "package": (("AppData", "Local", "Packages", "Claude_abc", "LocalCache", "Roaming", "Claude",
                 "Local Storage", "leveldb", "package.log"),
                r"%LOCALAPPDATA%\Packages\Claude_abc\LocalCache\Roaming\Claude"),
}


@pytest.mark.parametrize("layout", ["old", "claude_data", "logs", "package", "both"])
def test_claude_desktop_data_layouts(layout, tmp_path):
    prof = str(tmp_path / USER)
    os.makedirs(prof)
    layouts = ("old", "claude_data") if layout == "both" else (layout,)
    for age, name in enumerate(layouts[::-1], 1):
        touch(os.path.join(prof, *CLAUDE_DESKTOP_LAYOUTS[name][0]), b"PRIVATE_CLAUDE_DATA", age)
    d, raw, page = run(prof, str(tmp_path / "out"))
    matches = [e for e in d["evidence"] if e["id"] == "claude-desktop-data"]
    assert len(matches) == 1 and matches[0]["present"] is True
    r = matches[0]["result"]
    assert r["summary"]["files"] == len(layouts)
    assert r["summary"]["newest"] == "2026-10-12T12:00:00Z"
    assert set(r["found_locations"]) == {CLAUDE_DESKTOP_LAYOUTS[name][1] for name in layouts}
    assert USER not in raw and USER not in page and "PRIVATE_CLAUDE_DATA" not in raw + page


def test_claude_desktop_empty_package_marker_is_not_evidence(tmp_path):
    prof = str(tmp_path / USER)
    touch(os.path.join(prof, "AppData", "Local", "Packages", "Claude_abc", "LocalCache",
                       "Roaming", "Claude", ".user-data-left-after-uninstall"), b"", 0)
    d, raw, page = run(prof, str(tmp_path / "out"))
    assert item(d, "claude-desktop-data")["present"] is False
    assert USER not in raw and USER not in page


def test_desktop_package_reparse_directory_is_not_followed(tmp_path):
    prof = str(tmp_path / USER)
    outside = tmp_path / "outside"
    touch(str(outside / "LocalCache" / "Local" / "Codex" / "Logs" / "outside.log"), b"PRIVATE_OUTSIDE", 0)
    package_dir = tmp_path / USER / "AppData" / "Local" / "Packages"
    package_dir.mkdir(parents=True)
    link = package_dir / "OpenAI.Codex_redirect"
    try:
        os.symlink(outside, link, target_is_directory=True)
    except OSError:
        # A junction exercises the same reparse-point guard without Developer Mode.
        link_arg = str(link).replace("'", "''")
        target_arg = str(outside).replace("'", "''")
        created = subprocess.run(
            ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command",
             f"New-Item -ItemType Junction -Path '{link_arg}' -Target '{target_arg}' -ErrorAction Stop | Out-Null"],
            capture_output=True, text=True, check=False)
        if created.returncode != 0:
            pytest.skip(f"directory reparse points unavailable: {created.stdout}{created.stderr}")
    d, raw, page = run(prof, str(tmp_path / "out"))
    linked = item(d, "chatgpt-desktop-logs")
    assert linked["present"] is None and linked["result"]["partial"] is True
    assert linked["result"]["note"] == "This folder is a link to another location. LUMINOL does not follow links, so it was not checked."
    assert USER not in raw and USER not in page and "PRIVATE_OUTSIDE" not in raw + page


# ---- stress-test fixes (2026-10-18) ------------------------------------------------------------------------------
def run_in(profile, out, before, expect=0):
    """Run the check after a PowerShell statement (culture, language mode) in the same session."""
    inner = (f"{before}; & '{SCRIPT}' -ProfileRoot '{profile}' -OutDir '{out}' -NoOpen -Now '{NOW.isoformat()}'; "
             "exit $LASTEXITCODE")
    p = subprocess.run(["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", inner],
                       capture_output=True, text=True, timeout=300)
    assert p.returncode == expect, p.stdout + p.stderr
    return p


@pytest.mark.parametrize("culture", ["ar-SA", "th-TH", "de-DE"])
def test_dates_stay_gregorian_and_english_on_any_windows_calendar(profile, tmp_path, culture):
    # Saudi Arabic Windows writes the year as 1448 and Thai Windows as 2569 by default: every deadline would be off by
    # centuries. Report data, file names and the notice must not depend on the Windows calendar or language.
    run_in(profile, str(tmp_path), f"[Threading.Thread]::CurrentThread.CurrentCulture = '{culture}'; "
                                   f"[Threading.Thread]::CurrentThread.CurrentUICulture = '{culture}'")
    name = [f for f in os.listdir(tmp_path) if f.endswith(".json")][0]
    assert name.startswith("LUMINOL-Check_2026-10-13_"), name
    with open(os.path.join(tmp_path, name), encoding="utf-8") as f:
        d = json.load(f)
    assert d["generated_at"] == "2026-10-13T12:00:00Z"
    assert d["generated_local"].endswith("October 2026, " + d["generated_local"][-5:]) and d["generated_local"].isascii()
    deadlines = [e["clock"]["deadline"] for e in d["evidence"] if e.get("clock") and e["clock"].get("deadline")]
    assert deadlines and all(x[:4] in ("2026", "2027") for x in deadlines), deadlines
    assert "13 October 2026" in d["hold_notice"]["text"]


def test_site_names_in_any_capitals_are_found_fast(tmp_path):
    prof = str(tmp_path / USER)
    hist = os.path.join(prof, "AppData", "Local", "Google", "Chrome", "User Data", "Default", "History")
    # 9 MB file, mixed-case name placed across the 4 MB read boundary
    data = bytearray(9 * 1024 * 1024)
    name = b"https://ChatGPT.COM/c/abc"
    data[4 * 1024 * 1024 - 10:4 * 1024 * 1024 - 10 + len(name)] = name
    touch(hist, bytes(data))
    out = tmp_path / "out"
    out.mkdir()
    t = time.time()
    d = run(prof, str(out))[0]
    chrome = [p for p in item(d, "browser-history")["result"]["profiles"] if p["browser"] == "Chrome"][0]
    assert "ChatGPT" in chrome["services"]
    assert time.time() - t < 60


def test_locked_down_pc_gets_a_plain_message(profile, tmp_path):
    p = run_in(profile, str(tmp_path), "$ExecutionContext.SessionState.LanguageMode = 'ConstrainedLanguage'", expect=3)
    assert "Constrained Language Mode" in p.stdout and "Nothing was checked" in p.stdout
    assert not os.listdir(tmp_path)


def test_unwritable_report_folder_is_explained(profile, tmp_path):
    blocked = tmp_path / "not-a-directory"
    blocked.write_text("x")
    cmd = ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", SCRIPT, "-ProfileRoot", profile,
           "-OutDir", str(blocked), "-NoOpen", "-Now", NOW.isoformat()]
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    assert p.returncode == 4 and "cannot write the report" in p.stdout, p.stdout + p.stderr


# ---- report escaping (strategy L3, 2026-11-06) ----------------------------------------------------------------------
# The HTML report shows text that comes from the computer (browser profile folder names, file paths, problem notes,
# the Windows name). It must show that text as text and never run it. Windows file and folder names cannot contain
# < > or ", so the end-to-end test plants a real profile folder with ' and &; the template test renders a report whose
# every free-text value carries tag, attribute and </script> payloads. Both open the page in headless Microsoft Edge
# and read the resulting page, so the browser itself decides what was escaped.
from html.parser import HTMLParser

EDGE = next((p for p in (os.path.join(os.environ.get("ProgramFiles(x86)", ""), r"Microsoft\Edge\Application\msedge.exe"),
                         os.path.join(os.environ.get("ProgramFiles", ""), r"Microsoft\Edge\Application\msedge.exe"))
             if os.path.isfile(p)), None)
needs_edge = pytest.mark.skipif(EDGE is None, reason="Microsoft Edge not installed")
PROBE = "luminolprobe"
HOSTILE = ("<img id=" + PROBE + " src=x onerror=\"document.title='" + PROBE + "'\">"
           "\" onmouseover=\"document.title='" + PROBE + "'\" x=\"' onfocus='document.title=1' "
           "</script><script>document.title='" + PROBE + "'</script>")
# Values the template uses as structure (ids, status keys, links, dates), not as free text.
STRUCTURAL = {"id", "status", "kind", "schema", "engine", "service", "service_ids", "source", "also_sources", "url",
              "deadline", "generated_at", "modified", "newest", "oldest", "type", "parameters", "readable"}


class _Dom(HTMLParser):
    def __init__(self):
        super().__init__()
        self.tags, self.title, self._in_title = [], "", False

    def handle_starttag(self, tag, attrs):
        self.tags.append((tag, dict(attrs)))
        self._in_title = tag == "title"

    def handle_endtag(self, tag):
        self._in_title = False

    def handle_data(self, data):
        if self._in_title:
            self.title += data


def rendered(html_text, tmp):
    """The page as Edge builds it after the report's script has run."""
    path = os.path.join(tmp, "report.html")
    with open(path, "w", encoding="utf-8") as f:
        f.write(html_text)
    p = subprocess.run([EDGE, "--headless=new", "--disable-gpu", "--no-first-run", "--disable-background-networking",
                        "--disable-component-update", "--disable-extensions", "--user-data-dir=" + os.path.join(tmp, "edge"),
                        "--dump-dom", "file:///" + path.replace("\\", "/")],
                       capture_output=True, text=True, encoding="utf-8", timeout=180)
    assert 'id="report"' in p.stdout, p.stderr[-2000:]
    dom = _Dom()
    dom.feed(p.stdout)
    return p.stdout, dom


def assert_nothing_ran(dom, text):
    assert PROBE not in dom.title and dom.title.strip() != "1", dom.title
    assert not [t for t, a in dom.tags if a.get("id") == PROBE or (t == "img" and a.get("src") == "x")]
    injected = [(t, a) for t, a in dom.tags for k, v in a.items()
                if k in ("onerror", "onmouseover", "onfocus") or (k.startswith("on") and PROBE in (v or ""))]
    assert not injected, injected[:3]
    assert not [t for t, a in dom.tags if t == "script" and not a][1:], "an extra inline script appeared"


def poison(v, key=None):
    if isinstance(v, dict):
        return {k: (v[k] if k in STRUCTURAL else poison(v[k], k)) for k in v}
    if isinstance(v, list):
        return [poison(x, key) for x in v]
    if isinstance(v, str) and v:
        return v + " " + HOSTILE
    return v


@needs_edge
def test_report_template_shows_hostile_text_as_text(result, tmp_path):
    d = poison(result[0])
    d["problems"] = [HOSTILE]                       # also a value that is nothing but the payload
    with open(os.path.join(ROOT, "src", "report-template.html"), encoding="utf-8") as f:
        template = f.read()
    # Same embedding as Luminol-Check.ps1: the JSON goes into the page with '</' written as '<\/'.
    page = template.replace("/*__LUMINOL_DATA__*/null", json.dumps(d).replace("</", "<\\/"))
    text, dom = rendered(page, str(tmp_path))
    assert_nothing_ran(dom, text)
    assert "&lt;img id=" + PROBE in text            # the payload is on the page, as visible text
    assert text.count("&lt;img id=" + PROBE) >= 5   # in several places (problems, profiles, notes, Windows name...)


@needs_edge
def test_real_report_shows_machine_names_as_text(tmp_path_factory):
    base = tmp_path_factory.mktemp("hostile-profile")
    prof = str(base / USER)
    name = "x' onmouseover='document.title=1' & Co"   # a real folder name: Windows allows ' and & but not < > "
    touch(os.path.join(prof, "AppData", "Roaming", "Mozilla", "Firefox", "Profiles", name, "places.sqlite"),
          b"SQLite format 3\x00 chatgpt.com", 1)
    d, raw, page = run(prof, str(tmp_path_factory.mktemp("hostile-out")))
    ff = [p for p in item(d, "browser-history")["result"]["profiles"] if p["browser"] == "Firefox"][0]
    assert ff["profile"] == name and "ChatGPT" in ff["services"]
    text, dom = rendered(page, str(tmp_path_factory.mktemp("hostile-edge")))
    assert_nothing_ran(dom, text)
    assert "x' onmouseover='document.title=1' &amp; Co" in text   # shown as text, & escaped
