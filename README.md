# LUMINOL by Shadow AI Forensics

Forensic suites show what AI evidence is on a computer. LUMINOL shows how long it will stay there.

LUMINOL is a free Windows check from [Shadow AI Forensics](https://shadowaiforensics.com). It checks 19 kinds of
evidence, each covered by a positive and a negative synthetic test.

## Limits

- Authorised use. Run LUMINOL only on a computer you own or have authority to examine. The report is personal data about the person who uses that computer; handle it as you would their email.
- The report records what this computer shows on the day of the check. It is not legal advice, and no report guarantees that a court or regulator will accept it.
- A missing result does not prove AI was not used. Cleared history, private windows and use on another account or device may leave no trace for this check.
- It checks known locations in the current Windows account. Files whose full path is longer than 260 characters are
  not read; the report marks that location as not fully checked. It cannot show what vendors hold in an account, what
  is on another device, or what was deleted before the check.
- LUMINOL 0.1.1 does not yet check two files the ChatGPT desktop app keeps under .codex: history.jsonl and sqlite\codex-dev.db. This is planned for 0.1.2.
- It checks the Windows account it runs in; run it in the account of the person whose computer it is.
- If you suspect a specific person, do not ask them to run it. Have IT run it, or contact us before anything on that computer is changed.
- It reports whether a record exists and when its file last changed. It does not keep or report conversation text, and it cannot prove what a person said.
- Its lifetime estimates combine dated lab observations, vendor pages and Windows behavior. Lab observations came
  from one machine; each measured item names its app version where recorded. Other versions may differ. Vendor windows are subject to the vendor's
  stated exceptions. The report identifies the source for each estimate and marks unmeasured items.
- Windows security policy may block PowerShell scripts. Company security software may block an unsigned script
  like this one. Ask your IT team.
- Tested on one Windows build (Windows 11 Pro 26300) with Windows PowerShell 5.1. LUMINOL 0.1.1 is not code-signed, so Windows SmartScreen may show "Windows protected your PC". Verify the SHA-256 before you run it (see Check the download and the code).
- Measured on one PC on 30 and 31 October 2026: a check took 10 to 34 seconds. The time grows with the number of cache files the AI apps keep.
- If LUMINOL says a browser is open, it may only have seen the browser's name in the list of running programs. That does not prove its history is locked. Some browsers can be set to clear history or site data when they close, so closing a browser can delete evidence. Check that setting first, or let LUMINOL run with the browser open. The check runs either way.
- This is a live check. LUMINOL does not change the contents, size, dates or attributes of any file it checks, except
  that Windows may update the last-access time of files and folders it reads. Read the
  [measured changes and limits](WHAT-IT-CHANGES.md) before treating the report as forensic evidence.

## How LUMINOL is built

Adil Ali directs LUMINOL and is responsible for it. Much of the code and tests were written with AI coding assistants (Anthropic's Claude and OpenAI's Codex). Nothing ships on trust in an assistant: every release must pass the full test suite, build twice to a byte-identical zip, pass a tamper test and a review by a separate AI session that did not write the code, and its exact SHA-256 is published.

## Run it

Download LUMINOL only from github.com/adilshadowaiforensics/luminol. We publish no other copy. Check the SHA-256 before you run it.

1. Download `LUMINOL-Check-<version>.zip` and `LUMINOL-Check-<version>.zip.sha256` from Releases. Verify the SHA-256 (see Check the download and the code).
2. Unblock the verified zip: right-click it, choose **Properties**, tick **Unblock**, click **OK**. Windows marks every file extracted from a downloaded zip as coming from the internet, and Smart App Control blocks a .cmd file that carries that mark. Unblocking the zip you verified clears the mark from every file inside it. If there is no Unblock box, the zip is already unblocked. If you skipped that step, Windows may show "The publisher could not be verified". This is expected: LUMINOL 0.1.1 is not code-signed. Check the zip's SHA-256 first, then click Run.
3. Right-click the zip and choose **Extract All**.
4. Double-click **LUMINOL.cmd**, then choose **Check this computer**. If the window cannot load, use
   **Run LUMINOL Check.cmd** in the extracted folder.
5. Read the results in the window or open the HTML report. LUMINOL saves HTML and JSON in Documents\LUMINOL, with
   a reported fallback to Desktop\LUMINOL or the user's temporary folder if Documents is unavailable.

LUMINOL saves its report in Documents\LUMINOL (Desktop\LUMINOL if Documents cannot be written). If Windows backs that folder up to OneDrive, the report (which lists file, folder and account names) is copied to the cloud too. Move it out of the synced folder before sharing it.

LUMINOL runs without administrator rights and installs nothing. It checks only the Windows account it runs in.

LUMINOL makes no network connection unless you choose the optional seal. It has no updates, telemetry or crash reports.

The check works offline. The optional seal sends one 32-byte fingerprint to public OpenTimestamps servers. It saves
.seal.json and pending .ots files next to the report; a pending proof needs later upgrade and verification before
it supports a Bitcoin timestamp claim. A calendar also receives ordinary connection metadata such as an IP address.

The check reads file names, sizes and dates; it checks for AI site names in browser history and the Windows
notification database; and it reads the site recorded in downloaded files' Mark of the Web. It reports the site
matches, not the surrounding text. For example, our 2 October 2026 lab observation used the ChatGPT desktop app
Store package OpenAI.Codex 26.928 and .codex\.codex-global-state.json. LUMINOL reports whether that typed-prompt record exists and when its file last changed, not what it says.

The report includes sourced clocks, checks that were partial or unreadable, suggested next steps, and a preservation
notice that is a draft for your counsel to adapt.

## Why LUMINOL.cmd hides a console and passes -ExecutionPolicy Bypass

LUMINOL's window is a PowerShell app. LUMINOL.cmd hides the console behind that window; nothing else is hidden. -ExecutionPolicy Bypass applies to that single PowerShell process and changes no setting on the computer. Group Policy outranks it: where an organisation has set a script policy, LUMINOL names the policy and stops. In Constrained Language Mode it also stops and says so. Under Unrestricted, the console stays visible so Windows can ask before it runs a downloaded script. The launcher is 57 lines. Read src/LUMINOL.cmd before you run it.

## Check the download and the code

Compare the ZIP SHA-256 with its .sha256 sidecar, then compare files inside with SHA256SUMS.txt. The check is in
[Luminol-Check.ps1](src/Luminol-Check.ps1), the catalogue in [catalog.json](src/catalog.json), and the disclosure in
[What LUMINOL changes](WHAT-IT-CHANGES.md). The repository contains synthetic tests for the 19 evidence kinds.

Copyright 2026 Adil Ali, trading as Shadow AI Forensics. Apache License 2.0. Report a privacy or security issue using [SECURITY.md](SECURITY.md).

Running this for an organisation? We offer a free 15-minute deadline call: email contact@shadowaiforensics.com with
the subject "Deadline call". Ran it at work? Forward the report to your IT, legal or compliance team: it dates, for each kind of evidence in the Windows account it checked, when that evidence starts to disappear, and marks every kind whose lifetime is not yet measured.

LUMINOL is independent. It is not affiliated with or endorsed by OpenAI, Anthropic, Google, Cursor or any other vendor it names. Product names belong to their owners.
