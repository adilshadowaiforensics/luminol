@echo off
rem LUMINOL Check - double-click to run. Read-only, offline, no administrator rights needed.
if not exist "%~dp0Luminol-Check.ps1" goto notextracted
if not exist "%~dp0catalog.json" goto notextracted
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Luminol-Check.ps1" %*
echo.
pause
exit /b 0
:notextracted
echo.
echo  LUMINOL cannot start: its files are still inside the .zip file.
echo.
echo  Windows opened only this one file from the zip, without the others it needs.
echo  1. Close this window.
echo  2. Right-click the downloaded .zip file and choose "Extract All...", then "Extract".
echo  3. Open the new folder that appears and double-click this file again.
echo.
pause
exit /b 1
