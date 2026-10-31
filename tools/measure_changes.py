"""Measure what a LUMINOL run changes in a synthetic Windows profile.

Plants a synthetic user profile with every kind of evidence LUMINOL looks for, records each file's bytes (SHA-256),
size, creation / modification / last-access times (100 ns) and alternate data streams, runs the LUMINOL check
against it, records again and reports every difference. The NTFS change journal (USN) is read for the whole run
when the account may read it (`fsutil usn readjournal` needs an administrator): it shows every write to the volume,
including writes the timestamps would hide.

The check writes reports in the temporary profile's report folder. This probe writes its JSON summary to --out.
Run: python tools\\measure_changes.py --luminol . --out probe-results
Exit 0 means no content, size, creation, modification or metadata-change difference was detected in the planted
profile. Last-access changes are reported separately and do not count as a pass for trace-free operation.
"""
import argparse
import ctypes
import ctypes.wintypes as wt
import datetime as dt
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import winreg

NOW = dt.datetime(2026, 10, 13, 12, 0, 0, tzinfo=dt.timezone.utc)
USER = "LuminolProbeUserQX"
PLANTED_FILES = []


def touch(path, data=b"x", days_ago=0.0):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)
    t = (NOW - dt.timedelta(days=days_ago)).timestamp()
    os.utime(path, (t, t))
    PLANTED_FILES.append(path)


def plant(prof):
    """Every catalogue kind of LUMINOL 0.1.x, small synthetic files, old access times (so any read would show)."""
    L = os.path.join(prof, "AppData", "Local")
    R = os.path.join(prof, "AppData", "Roaming")
    sq = b"SQLite format 3\x00"
    touch(os.path.join(prof, ".codex", ".codex-global-state.json"), b"{}", 5)
    touch(os.path.join(L, "Codex", "Logs", "2026", "10", "12", "a.log"), b"log", 5)
    touch(os.path.join(prof, ".codex", "sessions", "2026", "10", "10", "rollout-x.jsonl"), b"{}", 5)
    touch(os.path.join(prof, ".codex", "logs_2.sqlite"), sq, 5)
    touch(os.path.join(prof, ".codex", "state_5.sqlite"), sq, 5)
    touch(os.path.join(prof, ".codex", "thread_history_1.sqlite"), sq, 5)
    touch(os.path.join(R, "Claude", "Local Storage", "leveldb", "000003.log"), b"x", 5)
    touch(os.path.join(prof, ".claude", "settings.json"), b'{"cleanupPeriodDays": 10}', 5)
    touch(os.path.join(prof, ".claude", "projects", "p1", "t.jsonl"), b"{}", 5)
    touch(os.path.join(R, "Cursor", "User", "globalStorage", "state.vscdb"), sq, 5)
    touch(os.path.join(R, "Code", "User", "globalStorage", "saoudrizwan.claude-dev", "tasks", "1", "api.json"), b"{}", 5)
    touch(os.path.join(prof, ".ollama", "history"), b"x", 5)
    chrome = os.path.join(L, "Google", "Chrome", "User Data", "Default")
    touch(os.path.join(chrome, "History"), sq + b"...https://chatgpt.com/c/abc...claude.ai/chat/x", 5)
    touch(os.path.join(chrome, "IndexedDB", "https_claude.ai_0.indexeddb.leveldb", "000003.log"), b"x", 5)
    touch(os.path.join(chrome, "IndexedDB", "https_chatgpt.com_0.indexeddb.leveldb", "000003.log"), b"x", 5)
    touch(os.path.join(L, "Microsoft", "Edge", "User Data", "Default", "History"), sq + b" gemini.google.com", 5)
    touch(os.path.join(L, "Microsoft", "Windows", "Notifications", "wpndatabase.db"), b"...OpenAI.Codex_2p2nqsd0c76g0!App", 5)
    dl = os.path.join(prof, "Downloads")
    touch(os.path.join(dl, "report.docx"), b"doc", 5)
    with open(os.path.join(dl, "report.docx") + ":Zone.Identifier", "w") as f:
        f.write("[ZoneTransfer]\nZoneId=3\nReferrerUrl=https://chatgpt.com/\n")
    t = (NOW - dt.timedelta(days=5)).timestamp()
    os.utime(os.path.join(dl, "report.docx"), (t, t))
    touch(os.path.join(R, "Microsoft", "Windows", "Recent", "report.docx.lnk"), b"L\x00\x00\x00", 5)


# --- file times at 100 ns, without following anything -----------------------------------------------------------
k32 = ctypes.WinDLL("kernel32", use_last_error=True)


class FILETIME(ctypes.Structure):
    _fields_ = [("lo", wt.DWORD), ("hi", wt.DWORD)]


class FILE_BASIC_INFO(ctypes.Structure):
    _fields_ = [("CreationTime", ctypes.c_longlong), ("LastAccessTime", ctypes.c_longlong),
                ("LastWriteTime", ctypes.c_longlong), ("ChangeTime", ctypes.c_longlong), ("FileAttributes", wt.DWORD)]


class WIN32_FIND_STREAM_DATA(ctypes.Structure):
    _fields_ = [("StreamSize", ctypes.c_longlong), ("cStreamName", ctypes.c_wchar * 296)]


k32.CreateFileW.restype = wt.HANDLE
k32.CreateFileW.argtypes = [wt.LPCWSTR, wt.DWORD, wt.DWORD, ctypes.c_void_p, wt.DWORD, wt.DWORD, wt.HANDLE]
k32.GetFileTime.argtypes = [wt.HANDLE, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
k32.SetFileTime.argtypes = [wt.HANDLE, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
k32.CloseHandle.argtypes = [wt.HANDLE]
k32.GetFileInformationByHandleEx.argtypes = [wt.HANDLE, ctypes.c_int, ctypes.c_void_p, wt.DWORD]
k32.SetFileInformationByHandle.argtypes = [wt.HANDLE, ctypes.c_int, ctypes.c_void_p, wt.DWORD]
k32.FindFirstStreamW.restype = wt.HANDLE
k32.FindFirstStreamW.argtypes = [wt.LPCWSTR, ctypes.c_int, ctypes.c_void_p, wt.DWORD]
k32.FindNextStreamW.argtypes = [wt.HANDLE, ctypes.c_void_p]
k32.FindClose.argtypes = [wt.HANDLE]
INVALID = wt.HANDLE(-1).value


def open_metadata_handle(path):
    # Open before resetting times; later snapshots use handles without path lookups.
    h = k32.CreateFileW(path, 0x180, 7, None, 3, 0x02000000, None)
    if h == INVALID:
        raise OSError(ctypes.get_last_error(), path)
    sentinel = FILETIME(0xffffffff, 0xffffffff)
    if not k32.SetFileTime(h, None, ctypes.byref(sentinel), None):
        k32.CloseHandle(h)
        raise OSError(ctypes.get_last_error(), path)
    return h


def times(h):
    # Handles are opened before the five-day reset. Reading them makes no child-path lookup.
    b = FILE_BASIC_INFO()
    if not k32.GetFileInformationByHandleEx(h, 0, ctypes.byref(b), ctypes.sizeof(b)):
        raise OSError(ctypes.get_last_error(), "GetFileInformationByHandleEx")
    return {"created": b.CreationTime, "accessed": b.LastAccessTime, "modified": b.LastWriteTime,
            "changed": b.ChangeTime, "attributes": b.FileAttributes}


def streams(path):
    out = []
    d = WIN32_FIND_STREAM_DATA()
    h = k32.FindFirstStreamW(path, 0, ctypes.byref(d), 0)
    if h == INVALID:
        return out
    try:
        while True:
            out.append([d.cStreamName, d.StreamSize])
            if not k32.FindNextStreamW(h, ctypes.byref(d)):
                break
    finally:
        k32.FindClose(h)
    return out


def planted_paths(root):
    """Known paths, parents before children; no directory enumeration after planting."""
    folders = set()
    for path in PLANTED_FILES:
        parent = os.path.dirname(path)
        while parent != root and os.path.commonpath((parent, root)) == root:
            folders.add(parent)
            parent = os.path.dirname(parent)
    return sorted(folders, key=lambda p: (p.count(os.sep), p)), sorted(PLANTED_FILES)


def reset_access(root, handles):
    folders, files = planted_paths(root)
    old = time.time_ns() // 100 + 116444736000000000 - 5 * 86400 * 10000000
    for path in files + list(reversed(folders)):
        b = FILE_BASIC_INFO()
        b.LastAccessTime = old
        if not k32.SetFileInformationByHandle(handles[path], 0, ctypes.byref(b), ctypes.sizeof(b)):
            raise OSError(ctypes.get_last_error(), path)
    return old


def snapshot(root, handles):
    snap = {}
    folders, files = planted_paths(root)
    for p in folders + files:
        rel = os.path.relpath(p, root)
        e = {"dir": p in folders}
        e.update(times(handles[p]))
        snap[rel] = e
    return snap


def inventory(root):
    _, files = planted_paths(root)
    return {os.path.relpath(p, root): {"size": os.path.getsize(p), "streams": streams(p)} for p in files}


def hashes(root):
    out = {}
    _, files = planted_paths(root)
    for p in files:
        with open(p, "rb") as f:
            out[os.path.relpath(p, root)] = hashlib.sha256(f.read()).hexdigest()
        for name, _size in streams(p):
            if name != "::$DATA":
                with open(p + name.rsplit(":", 1)[0], "rb") as f:
                    out[os.path.relpath(p, root) + name] = hashlib.sha256(f.read()).hexdigest()
    return out


def differences(before, after):
    changes = []
    for rel in sorted(set(before) | set(after)):
        b, c = before.get(rel), after.get(rel)
        if b is None or c is None:
            changes.append({"path": rel, "change": "created" if b is None else "deleted"})
            continue
        for k in ("size", "created", "modified", "changed", "attributes", "streams", "accessed"):
            if b.get(k) != c.get(k):
                changes.append({"path": rel, "change": k, "dir": b["dir"],
                                "before": b.get(k), "after": c.get(k)})
    return changes


def next_usn(volume):
    p = subprocess.run(["fsutil", "usn", "queryjournal", volume], capture_output=True, text=True)
    for line in p.stdout.splitlines():
        if line.strip().lower().startswith("next usn"):
            return int(line.split(":", 1)[1].strip(), 16)
    return None


def read_usn(volume, start, base):
    """USN records since `start` whose path is under `base` (fsutil gives file names; we match by name list)."""
    p = subprocess.run(["fsutil", "usn", "readjournal", volume, f"startusn={start}", "csv"], capture_output=True, text=True)
    if p.returncode != 0:
        return None, (p.stdout + p.stderr).strip()[:300]
    return p.stdout.splitlines(), None


def last_access_enabled():
    try:
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"SYSTEM\CurrentControlSet\Control\FileSystem") as key:
            raw, _ = winreg.QueryValueEx(key, "NtfsDisableLastAccessUpdate")
        return not bool(raw & 1)
    except OSError:
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--luminol", default=os.path.dirname(os.path.dirname(__file__)),
                    help="LUMINOL folder (repo root or extracted release)")
    ap.add_argument("--out", default=os.path.join(tempfile.gettempdir(), "luminol_probe_results"))
    a = ap.parse_args()
    enabled = last_access_enabled()
    if enabled is False:
        print("SKIP: last-access updates are disabled on this PC; no attributable access-time count is possible")
        return 3
    if enabled is None:
        print("SKIP: last-access update setting is unreadable on this PC")
        return 3
    src = os.path.join(a.luminol, "src") if os.path.isdir(os.path.join(a.luminol, "src")) else a.luminol
    script = os.path.join(src, "Luminol-Check.ps1")
    os.makedirs(a.out, exist_ok=True)
    work = tempfile.mkdtemp(prefix="luminol_probe_")
    prof = os.path.join(work, USER)
    report_dir = os.path.join(work, "report")
    plant(prof)
    folders, files = planted_paths(prof)
    names = {os.path.basename(p) for p in folders + files}
    handles = {path: open_metadata_handle(path) for path in folders + files}
    hb = hashes(prof)
    inv_before = inventory(prof)
    # Initial inventory opens can leave delayed access writes. Plant the old time until
    # one top-down read confirms every item has it; the control itself still runs once.
    for _ in range(6):
        old = reset_access(prof, handles)
        time.sleep(0.5)
        if all(v["accessed"] == old for v in snapshot(prof, handles).values()):
            break
    else:
        print("CONTROL FAILED: planted last-access times did not stabilize")
        print([(rel, v["accessed"]) for rel, v in snapshot(prof, handles).items() if v["accessed"] != old][:20])
        for h in handles.values():
            k32.CloseHandle(h)
        shutil.rmtree(work, ignore_errors=True)
        return 2
    control_before = snapshot(prof, handles)
    control_after = snapshot(prof, handles)
    control_changes = differences(control_before, control_after)
    if control_changes:
        print(f"CONTROL FAILED: probe changed {len(control_changes)} planted item fields; measurement is not attributable")
        print(control_changes[:20])
        for h in handles.values():
            k32.CloseHandle(h)
        shutil.rmtree(work, ignore_errors=True)
        return 2
    reset_access(prof, handles)
    before = snapshot(prof, handles)
    vol = os.path.splitdrive(work)[0] or "C:"
    usn0 = next_usn(vol)
    started = dt.datetime.now(dt.timezone.utc)
    p = subprocess.run(["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script, "-ProfileRoot",
                        prof, "-OutDir", report_dir, "-NoOpen", "-Now", NOW.isoformat()], capture_output=True, text=True,
                       timeout=600)
    after = snapshot(prof, handles)
    usn_lines, usn_err = read_usn(vol, usn0, prof) if usn0 is not None else (None, "journal not readable")
    inv_after = inventory(prof)
    ha = hashes(prof)

    for rel, values in inv_before.items():
        before[rel].update(values)
    for rel, values in inv_after.items():
        after[rel].update(values)

    changes = differences(before, after)
    content = [k for k in sorted(set(hb) | set(ha)) if hb.get(k) != ha.get(k)]
    usn_profile = []
    if usn_lines:
        hdr = usn_lines[0]
        for line in usn_lines[1:]:
            parts = [x.strip('"') for x in line.split(",")]
            if any(n in parts for n in names):
                usn_profile.append(line)
    hard = [c for c in changes if c["change"] != "accessed"] + [{"path": k, "change": "content"} for k in content]
    accessed_files = [c["path"] for c in changes if c["change"] == "accessed" and not c["dir"]]
    accessed_dirs = [c["path"] for c in changes if c["change"] == "accessed" and c["dir"]]
    la = subprocess.run(["fsutil", "behavior", "query", "disablelastaccess"], capture_output=True, text=True).stdout.strip()
    ver = subprocess.run(["cmd", "/c", "ver"], capture_output=True, text=True).stdout.strip()
    result = {
        "probe": "luminol_change_probe/2", "run_at": started.isoformat(), "windows": ver, "last_access_setting": la,
        "control": {"last_access_changed_files": 0, "last_access_changed_dirs": 0, "other_changes": 0},
        "luminol_script": script, "luminol_exit": p.returncode,
        "planted_files": len(files), "planted_dirs": len(folders),
        "content_size_creation_modification_changes": hard,
        "last_access_changed_files": accessed_files, "last_access_changed_dirs": accessed_dirs,
        "usn": {"readable": usn_lines is not None, "error": usn_err,
                "records_naming_planted_items": usn_profile[:500]},
        "report_files": sorted(os.listdir(report_dir)) if os.path.isdir(report_dir) else [],
        "verdict": "CONTENT_UNCHANGED" if (p.returncode == 0 and not hard) else "FAILED",
    }
    stamp = started.strftime("%Y%m%dT%H%M%SZ")
    path = os.path.join(a.out, f"luminol_change_probe_{stamp}.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(result, f, indent=1)
    print("CONTROL: 0 last-access changes (files and folders); 0 other changes")
    print(f"LUMINOL exit {p.returncode}; planted {result['planted_files']} files, {result['planted_dirs']} folders")
    print(f"content/size/creation/modification/metadata-change/attribute changes: {len(hard)}")
    for c in hard[:20]:
        print("  ", c)
    print(f"last-access changed: {len(accessed_files)} file(s), {len(accessed_dirs)} folder(s) ({la})")
    for x in accessed_files:
        print("   file:", x)
    print(f"USN journal readable: {usn_lines is not None}" + (f" ({usn_err})" if usn_err else "") +
          f"; records naming planted items: {len(usn_profile)}")
    for line in usn_profile[:40]:
        print("   ", line[:200])
    print(f"report folder: {result['report_files']}")
    print(f"RESULT: {result['verdict']}  ->  {path}")
    if p.returncode != 0:
        print(p.stdout[-800:], p.stderr[-800:])
    for h in handles.values():
        k32.CloseHandle(h)
    shutil.rmtree(work, ignore_errors=True)
    return 0 if result["verdict"] == "CONTENT_UNCHANGED" else 1


if __name__ == "__main__":
    sys.exit(main())
