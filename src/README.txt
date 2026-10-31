LUMINOL Check

Forensic suites show what AI evidence is on a computer. LUMINOL shows how long it will stay there.
Free Windows check from Shadow AI Forensics (shadowaiforensics.com). Apache License 2.0.

LIMITS
- A missing result does not prove AI was not used. Cleared history, private windows and use on another account or device may leave no trace for this check.
- The check searches known locations in the current Windows account. It cannot show what vendors hold in an
  account, what is on another device, or what was deleted before the check. Files whose full path is longer than
  260 characters are not read; the report marks that location as not fully checked.
- It checks the Windows account it runs in; run it in the account of the person whose computer it is.
- If you suspect a specific person, do not ask them to run it. Have IT run it, take a sealed snapshot first, or
  contact us.
- It reports whether a record exists and how old it is. It does not read conversation text or prove what a person said.
- Lifetime estimates come from one-machine lab observations, vendor pages and Windows behavior. Each measured item
  names its app version where recorded; other versions may differ. Vendor windows are subject to stated exceptions.
- Windows security policy may block PowerShell scripts. Company security software may block an unsigned script
  like this one. Ask your IT team.
- LUMINOL does not change the contents, size, dates or attributes of any file it checks - except that Windows may
  update the last-access time of files and folders it reads. This is a live check, not a forensic acquisition.

RUN IT
1. Right-click the downloaded ZIP and choose Extract All. Keep all the extracted files together.
2. Double-click LUMINOL.cmd, then choose Check this computer. If the window cannot load, use
   Run LUMINOL Check.cmd in the extracted folder.
3. Read the results in the window or open the HTML report. The HTML and JSON reports are saved in Documents\LUMINOL,
   with a reported fallback to Desktop\LUMINOL or the user's temporary folder if Documents is unavailable.

Run it as the person whose Windows account is being checked. No administrator rights are required where the
endpoint's script policy allows PowerShell. Close web browsers first for a more complete browser-history check.

WHAT THE CHECK READS
The check reads file names, sizes and dates; checks whether listed AI site names appear in browser history and
the Windows notification database; and checks downloaded files' Mark of the Web for a listed AI site. It reports
site matches, not surrounding text. The report includes sourced clocks, partial or unreadable checks, suggested
next steps and a preservation notice that is a draft for your counsel to adapt. The profile folder appears as
%USERPROFILE% in the report, not the Windows user name.

OPTIONAL TIMESTAMP
The check works offline. The optional seal sends one 32-byte fingerprint to public OpenTimestamps servers.
It saves .seal.json and pending .ots files beside the report. A pending proof needs later upgrade and verification
before it supports a Bitcoin timestamp claim. The calendar also receives ordinary connection metadata, such as
an IP address. Without a timestamp request, the check makes no calendar request.

CHECK THE DOWNLOAD
Compare the ZIP SHA-256 with its .sha256 sidecar, then compare files inside with SHA256SUMS.txt.
Luminol-Check.ps1 is the check; catalog.json lists the evidence kinds and clocks; report-template.html renders the
HTML report. Luminol-App.ps1 and ui\MainWindow.xaml supply the window. Luminol-Seal.ps1 performs optional sealing.

CONTACT
Running this for an organisation? We offer a free 15-minute deadline call: email contact@shadowaiforensics.com with
the subject "Deadline call". Ran it at work? Forward the report to your IT, legal or compliance team: it shows the
date the evidence on this computer starts to disappear.
