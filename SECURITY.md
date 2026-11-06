# Security and privacy issues

LUMINOL does not keep, report or send conversation text. To find AI site names it scans the bytes of browser history files and the Windows notification database, which can contain page titles and notification text; it keeps only the matched site names, dates and counts. LUMINOL does not change the contents, size, dates or attributes of any file
it checks, except that Windows may update the last-access time of files and folders it reads;
see [What LUMINOL changes](WHAT-IT-CHANGES.md). If you find a case where it reads more than it says, changes source
content or metadata beyond the documented effects, sends data unexpectedly over the network, or shows personal data
in a report, please report it privately to **contact@shadowaiforensics.com** (subject "Security") before opening a public issue. Include the LUMINOL
version (shown at the bottom of every report) and your Windows version.

Do not paste your LUMINOL report or screenshots of it here. It contains file names, folder names and account names from your computer, and this page is public. Describe the problem in your own words.

Please do not send reports that contain real personal data. The JSON report never contains conversation text, but
it does list which AI services were seen in the locations checked.
