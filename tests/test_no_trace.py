"""Attribution probe on an isolated synthetic Windows profile."""
import json
import os
import subprocess
import sys
import winreg
from pathlib import Path

import pytest


@pytest.mark.probe
def test_luminol_change_probe(tmp_path):
    try:
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"SYSTEM\CurrentControlSet\Control\FileSystem") as key:
            raw, _ = winreg.QueryValueEx(key, "NtfsDisableLastAccessUpdate")
    except OSError:
        pytest.skip("last-access update setting is unreadable on this PC")
    if raw & 1:
        pytest.skip("last-access updates are disabled on this PC")
    root = Path(__file__).resolve().parents[1]
    out = tmp_path / "result"
    p = subprocess.run([sys.executable, str(root / "tools" / "measure_changes.py"),
                        "--luminol", str(root), "--out", str(out)],
                       capture_output=True, text=True, timeout=120,
                       env={**os.environ, "TMPDIR": str(tmp_path), "TEMP": str(tmp_path), "TMP": str(tmp_path)})
    assert p.returncode == 0, p.stdout + p.stderr
    result = json.loads(next(out.glob("*.json")).read_text(encoding="utf-8"))
    assert result["control"] == {"last_access_changed_files": 0,
                                 "last_access_changed_dirs": 0, "other_changes": 0}
    assert result["luminol_exit"] == 0
    assert result["content_size_creation_modification_changes"] == []
    assert isinstance(result["last_access_changed_files"], list)
    assert isinstance(result["last_access_changed_dirs"], list)
    assert result["verdict"] == "CONTENT_UNCHANGED"
