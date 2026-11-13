@echo off
setlocal
cd /d "%~dp0"

if not exist ".venv\Scripts\python.exe" (
    echo Creating virtual environment...
    python -m venv .venv
    .venv\Scripts\python.exe -m pip install -r requirements.txt
)

rem Tells the bot it may restart itself to apply yt-dlp updates.
set IXMUSIC_LAUNCHER=1

:loop
echo Updating yt-dlp...
.venv\Scripts\python.exe -m pip install -q --disable-pip-version-check -U "yt-dlp[default]"
.venv\Scripts\python.exe bot.py
if "%errorlevel%"=="3" (
    echo Restarting to apply the yt-dlp update...
    goto loop
)

echo Bot stopped with exit code %errorlevel%.
pause
