# What a LUMINOL check changes

LUMINOL Check reads local evidence and writes an HTML report and a JSON report. LUMINOL does not change the
contents, size, dates or attributes of any file it checks, except that Windows may update the last-access time of
files and folders it reads. Do not treat a normal check as a trace-free forensic acquisition.

## Measured on 24 October 2026

We ran the [synthetic change probe](tools/measure_changes.py) three times against v0.1.1 source commit
`6f7ec67` on 24 October 2026, Windows 11 build 26300.9711. `NtfsDisableLastAccessUpdate = 2`
(`DisableLastAccess = 2` from `fsutil`): system managed,
updates enabled. The probe planted 19 files and 46 folders in a fake profile. It set every planted item's last-access
time to five days earlier, then measured through known paths and handles without listing folders.

**Control first:** each before/after measurement without LUMINOL changed **0 file and 0 folder last-access
times**, and **0 other measured fields**. The check then exited successfully in all three runs. Last-access changed
on **5 files in each run and 23 to 25 folders** (25, 23, 23 across the three runs). The files were Chrome and Edge History, the Windows notification database, Claude Code
settings, and a downloaded file with a `Zone.Identifier` stream. Content hashes, sizes, creation and
modification times, NTFS ChangeTime, attributes, and alternate stream names and sizes had **0 changes**. These counts
are attributable to the check on this machine and synthetic profile; they are not a prediction for every PC. The
[three-run probe record](docs/testing/l4-measurement-2026-10-24.json) lists each changed path and control. The
[23 October result](docs/testing/l2b-measurement-2026-10-23.json) remains available as history.

The 23 folders whose last-access times changed in every run were:

- `.claude\projects`, `.claude\projects\p1`, `.codex`, `.codex\sessions`, `.codex\sessions\2026`,
  `.codex\sessions\2026\10`, `.codex\sessions\2026\10\10`, and `.ollama`;
- `AppData\Local\Codex\Logs`, its `2026`, `2026\10`, and `2026\10\12` subfolders;
- `AppData\Local\Google\Chrome\User Data` and the `Default\IndexedDB\https_chatgpt.com_0.indexeddb.leveldb`
  and `Default\IndexedDB\https_claude.ai_0.indexeddb.leveldb` folders beneath it; `AppData\Local\Microsoft\Edge\User Data`;
- `AppData\Roaming\Claude`, `AppData\Roaming\Claude\Local Storage`,
  `AppData\Roaming\Claude\Local Storage\leveldb`, `AppData\Roaming\Code\User\globalStorage\saoudrizwan.claude-dev\tasks`
  and its `1` subfolder;
- `AppData\Roaming\Microsoft\Windows\Recent` and `Downloads`.

The 25-folder run also recorded the parent folders `AppData` and `AppData\Local`. Every changed folder is a catalogue
read location or a parent of one. Between 23 and 24 October the measured folder count changed from 23 to a range of **23 to 25**
because the check now also looks in the newer folders the Claude and ChatGPT desktop apps use.

### Administrator check, 29 October 2026

On 29 October 2026, on Windows 11 build 26300, an administrator compared the NTFS change journal (USN) in two windows
of the same length: 30 seconds with no check running, then 30 seconds in which LUMINOL checked the signed-in profile
without a timestamp request ([audit_admin_run.ps1](tools/audit_admin_run.ps1)). In the check window the journal
recorded no change to any evidence file LUMINOL reads (browser history, agent session files and databases, the
notification database, Recent shortcuts) and no alternate-data-stream change. The journal does not record
last-access updates; those are measured by the probe above.

These journal changes appeared because the check ran:

- the report folder, the HTML and JSON report, and a small write-test file created and deleted in that folder;
- Windows PowerShell's own start-up: two policy-test files created and deleted in the user's temporary folder, and
  its start-up cache file updated;
- the Windows Prefetch record of the WMI provider host, which answers the check's Windows-version query. Prefetch
  records show that a program ran, so an examiner can see that a check was run.

The other records in both windows came from programs running in the background (browsers, OneDrive, Office). The
check process was polled 24 times during its 29-second run and opened no network connection. One computer, one run:
settings, file systems and endpoint controls can change the result.

## Files and network activity

- A normal run writes HTML and JSON in `Documents\LUMINOL`. If that folder is unavailable, the app tries
  `Desktop\LUMINOL`, then the user's temporary folder, and reports the fallback. It briefly creates and removes a
  writability test file in the report folder. With the default interface, it also opens the HTML report.
- With **Timestamp** selected, LUMINOL additionally writes a `.seal.json` file and any returned `.ots` proof files
  beside the report. It sends a randomized 32-byte fingerprint derived from the report to public OpenTimestamps
  calendars. The request also exposes ordinary network metadata, such as the connection's IP address, to the
  calendar service. Without Timestamp, the check makes no calendar request.
- Windows and PowerShell can create process, execution or other system records. The probe does not inventory those
  records. The current v0.1.1 check does not compile an embedded C# helper with `Add-Type`.

## Repeat the probe

On Windows with Python 3.8 or later, from a source checkout or extracted LUMINOL folder:

```powershell
fsutil behavior query disablelastaccess
python tools\measure_changes.py --luminol . --out probe-results
```

The command uses a synthetic profile in the system temporary folder and puts a JSON summary in `probe-results`.
It prints the control and LUMINOL counts and lists any changed planted items. Its exit code is zero when the control
has no changes and planted content and the non-access metadata above were unchanged; **read the last-access counts
separately**. It skips with an explanation if last-access updates are disabled or the setting is unreadable. An administrator can run the
same probe to add a USN-journal observation, subject to the probe's current journal matching limits.
