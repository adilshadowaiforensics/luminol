@echo off
rem LUMINOL - double-click to open the app. Read-only, offline, no administrator rights needed.
rem Plain report without the window: "Run LUMINOL Check.cmd".
if not exist "%~dp0Luminol-App.ps1" goto notextracted
if not exist "%~dp0Luminol-Check.ps1" goto notextracted
if not exist "%~dp0ui\MainWindow.xaml" goto notextracted
rem "-ExecutionPolicy Bypass" applies to this one PowerShell process only and changes no setting. A policy set by the
rem organisation through Group Policy still wins over it: then LUMINOL says so and stops instead of failing silently.
set "LUMINOL_POLICY="
for /f "usebackq delims=" %%p in (`""%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "Get-ExecutionPolicy""`) do set "LUMINOL_POLICY=%%p"
if "%LUMINOL_POLICY%"=="" goto locked
if /i "%LUMINOL_POLICY%"=="Bypass" goto policyok
if /i "%LUMINOL_POLICY%"=="Unrestricted" goto policyok
goto grouppolicy
:policyok
rem Locked-down company PCs run unapproved scripts in "Constrained Language Mode"; the window would never appear.
set "LUMINOL_LM="
for /f "usebackq delims=" %%m in (`""%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -Command "$ExecutionContext.SessionState.LanguageMode""`) do set "LUMINOL_LM=%%m"
if /i not "%LUMINOL_LM%"=="FullLanguage" goto locked
rem Unrestricted (set by the organisation) may ask before running a downloaded script, so keep that console visible.
if /i "%LUMINOL_POLICY%"=="Unrestricted" (
  start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Luminol-App.ps1"
  exit /b 0
)
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0Luminol-App.ps1"
exit /b 0
:grouppolicy
echo.
echo  LUMINOL cannot run on this computer.
echo.
echo  Your organisation has set the PowerShell script policy to "%LUMINOL_POLICY%" through Group Policy,
echo  and LUMINOL respects it. Nothing was checked and nothing was changed.
echo  Ask your IT department to run LUMINOL for you, or to allow it.
echo.
pause
exit /b 3
:locked
echo.
echo  LUMINOL cannot run on this computer.
echo.
echo  Its security settings only let approved scripts run (PowerShell "Constrained Language Mode",
echo  usually set by the IT department). Nothing was checked and nothing was changed.
echo  Ask your IT department to run LUMINOL for you, or to allow it.
echo.
pause
exit /b 3
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
