@echo off
rem Double-click to start IxMusicBot. All the logic is in start.ps1.
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1"
echo.
pause
