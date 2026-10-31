# Changelog

## 0.1.1 (2026-11-02)

Initial public release.

- Each of the 19 catalogue evidence kinds has a positive and a negative synthetic test.
- The report identifies partial scans and unreadable locations. Repeat scans use distinct report names, preserving earlier sealed reports.
- The check discloses last-access updates. On a synthetic profile on Windows 11 build 26300.9711, three 24 October 2026 runs recorded 5 files and 23 to 25 folders with changed last-access times; other measured fields were unchanged. See [What LUMINOL changes](WHAT-IT-CHANGES.md).
- A normal check works offline. The optional OpenTimestamps request sends one randomized 32-byte fingerprint to public calendars and saves pending proof files. A pending proof requires later upgrade and verification.
- The preservation notice is a draft for counsel to adapt. Lifetime estimates name their lab or vendor basis and the limits of that basis.

## 0.1.0 (2026-10-20, internal test build, never published)

- `LUMINOL.cmd` opened the app window, which ran the check and displayed the findings, clocks, sources, limits and a draft preservation notice.
- `Luminol-Check.ps1` ran under Windows PowerShell 5.1 without administrator rights where endpoint policy permitted scripts. It produced HTML and JSON reports in `Documents\LUMINOL`, with reported fallback locations.
- The catalogue covered 19 evidence kinds. Some lifetimes were based on one-machine lab observations, some on vendor pages or Windows behavior, and others were marked unmeasured.
- The check read file metadata and site-name matches without reading conversation text. The optional timestamp action sent a 32-byte report fingerprint to public OpenTimestamps calendars; proof files started pending.
