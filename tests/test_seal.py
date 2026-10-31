"""Opt-in sealed snapshot: a fake OpenTimestamps calendar on this computer records exactly what is sent."""
import hashlib
import json
import os
import socket
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest

import test_app as ta
import test_check as tc

ROOT = tc.ROOT
CHECK = os.path.join(ROOT, "src", "Luminol-Check.ps1")
PENDING = b"\x00" + bytes.fromhex("83dfe30d2ef90c8e")
URI = b"https://fake.calendar.example"
ATTESTATION = PENDING + bytes([len(URI) + 1, len(URI)]) + URI


class Calendar:
    def __init__(self):
        self.requests = []
        cal = self

        class H(BaseHTTPRequestHandler):
            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
                cal.requests.append({"path": self.path, "body": body, "accept": self.headers.get("Accept")})
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.end_headers()
                self.wfile.write(ATTESTATION)

            def log_message(self, *a):
                pass

        self.server = HTTPServer(("127.0.0.1", 0), H)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    @property
    def urls(self):
        return [f"http://127.0.0.1:{self.port}", f"http://localhost:{self.port}"]


@pytest.fixture()
def cal():
    c = Calendar()
    yield c
    c.server.shutdown()


@pytest.fixture(scope="module")
def prof(tmp_path_factory):
    return tc.profile.__wrapped__(tmp_path_factory)


def run_check(profile, out, *extra):
    p = subprocess.run(["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", CHECK, "-ProfileRoot", profile,
                        "-OutDir", str(out), "-NoOpen", "-Now", tc.NOW.isoformat()] + list(extra), capture_output=True, text=True, timeout=300)
    assert p.returncode == 0, p.stdout + p.stderr
    return p.stdout


def ots_info(path):
    from opentimestamps.core.timestamp import DetachedTimestampFile
    from opentimestamps.core.serialize import BytesDeserializationContext
    t = DetachedTimestampFile.deserialize(BytesDeserializationContext(open(path, "rb").read()))
    return t.file_digest, [str(a) for _, a in t.timestamp.all_attestations()]


def test_default_run_sends_nothing(prof, tmp_path, cal):
    run_check(prof, tmp_path, "-TimestampCalendars", cal.urls[0])  # calendars given but no -Timestamp
    assert cal.requests == []
    assert not [f for f in os.listdir(tmp_path) if ".seal." in f]
    d = json.load(open([os.path.join(tmp_path, f) for f in os.listdir(tmp_path) if f.endswith(".json")][0], encoding="utf-8"))
    assert d["timestamp_requested"] is False and "sent nothing over the internet" in d["privacy"]


def test_timestamp_seals_both_files_and_sends_only_32_bytes(prof, tmp_path, cal):
    pytest.importorskip("opentimestamps")
    out = run_check(prof, tmp_path, "-Timestamp", "-TimestampCalendars", ",".join(cal.urls))
    assert "Timestamp proofs: 2 saved" in out, out
    assert len(cal.requests) == 2
    for r in cal.requests:
        assert r["path"] == "/digest" and len(r["body"]) == 32 and r["accept"] == "application/vnd.opentimestamps.v1"
    assert cal.requests[0]["body"] == cal.requests[1]["body"], "one commitment, sent to two calendars"
    files = os.listdir(tmp_path)
    seal = [f for f in files if f.endswith(".seal.json")][0]
    sealed = json.load(open(os.path.join(tmp_path, seal), encoding="utf-8"))
    for e in sealed["files"]:
        assert hashlib.sha256(open(os.path.join(tmp_path, e["file"]), "rb").read()).hexdigest() == e["sha256"]
    assert {e["file"].rsplit(".", 1)[1] for e in sealed["files"]} == {"html", "json"}
    digest = hashlib.sha256(open(os.path.join(tmp_path, seal), "rb").read()).digest()
    for proof in (seal + ".ots", seal + ".2.ots"):
        fd, atts = ots_info(os.path.join(tmp_path, proof))
        assert fd == digest and atts == ["PendingAttestation('https://fake.calendar.example')"]
    rep = json.load(open(os.path.join(tmp_path, seal.replace(".seal.json", ".json")), encoding="utf-8"))
    assert rep["timestamp_requested"] is True and "a 32-byte fingerprint" in rep["privacy"]


def test_offline_timestamp_keeps_the_report_and_says_so(prof, tmp_path):
    s = socket.socket(); s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]; s.close()  # nothing listens here
    out = run_check(prof, tmp_path, "-Timestamp", "-TimestampCalendars", f"http://127.0.0.1:{port}")
    assert "Timestamp failed" in out
    assert any(f.endswith(".html") for f in os.listdir(tmp_path)) and not any(f.endswith(".ots") for f in os.listdir(tmp_path))


def test_app_timestamp_button_path(prof, tmp_path, cal):
    s = ta.run_app(ta.APP, prof, str(tmp_path), "-SelfTestTimestamp", "-Calendars", ",".join(cal.urls))
    assert s["ok"] and s["timestamp_sealed"] is True, s
    assert s["timestamp_text"].startswith("Pending proof saved from 2 calendar(s)")
    assert "32-byte fingerprint" in s["timestamp_text"] and "connection metadata" in s["timestamp_text"]
    assert s["timestamp_button_enabled"] is False, "one timestamp per report"
    assert len(cal.requests) == 2 and all(len(r["body"]) == 32 for r in cal.requests)


def test_app_without_click_sends_nothing(prof, tmp_path, cal):
    s = ta.run_app(ta.APP, prof, str(tmp_path), "-Calendars", ",".join(cal.urls))
    assert s["ok"] and s["timestamp_button_enabled"] is True and s["timestamp_sealed"] is False
    assert cal.requests == []


@pytest.mark.skipif(os.environ.get("LUMINOL_OFFLINE") == "1", reason="offline run")
def test_live_calendars_from_windows_powershell(prof, tmp_path):
    """Real OpenTimestamps calendars with Windows PowerShell 5.1's own TLS (a.pool needs TLS 1.3, so b.pool/finney first)."""
    pytest.importorskip("opentimestamps")
    out = run_check(prof, tmp_path, "-Timestamp")
    if "Timestamp failed" in out:
        pytest.skip("no network: " + out[-300:])
    seal = [f for f in os.listdir(tmp_path) if f.endswith(".seal.json")][0]
    digest = hashlib.sha256(open(os.path.join(tmp_path, seal), "rb").read()).digest()
    proofs = [f for f in os.listdir(tmp_path) if f.endswith(".ots")]
    assert len(proofs) == 2
    for p in proofs:
        fd, atts = ots_info(os.path.join(tmp_path, p))
        assert fd == digest and atts and all(a.startswith("PendingAttestation") for a in atts)
