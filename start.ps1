#Requires -Version 5.1
<#
    IxMusicBot launcher (started by run.bat).
    1. Checks Python, Node.js and FFmpeg and offers to install missing ones with winget (asks first).
    2. Creates / repairs the virtual environment and installs requirements when they change.
    3. Makes sure .env exists and has a token.
    4. Runs the bot, updating yt-dlp before every start, and restarts it when it asks to (exit code 3).
#>

$ErrorActionPreference = 'Continue'
Set-Location -LiteralPath $PSScriptRoot

$VenvDir   = Join-Path $PSScriptRoot '.venv'
$VenvPy    = Join-Path $VenvDir 'Scripts\python.exe'
$ReqFile   = Join-Path $PSScriptRoot 'requirements.txt'
$ReqStamp  = Join-Path $VenvDir '.requirements.sha256'
$EnvFile   = Join-Path $PSScriptRoot '.env'
$EnvSample = Join-Path $PSScriptRoot '.env.example'
$MinPython = [version]'3.11'
$RestartExitCode = 3

# ---------- output helpers ----------

function Write-Msg([string]$En, [string]$Bg, [string]$Color = 'Gray') {
    Write-Host $En -ForegroundColor $Color
    if ($Bg) { Write-Host $Bg -ForegroundColor $Color }
}
function Write-Step([string]$En, [string]$Bg) { Write-Host ''; Write-Msg "== $En" $(if ($Bg) { "   $Bg" }) 'Cyan' }
function Write-Ok([string]$Text)              { Write-Host "   OK  $Text" -ForegroundColor Green }
function Write-Warn([string]$En, [string]$Bg) { Write-Msg "   !   $En" "       $Bg" 'Yellow' }
function Write-Fail([string]$En, [string]$Bg) { Write-Msg "   X   $En" "       $Bg" 'Red' }

function Confirm-Action([string]$En, [string]$Bg) {
    Write-Host "   ?   $En [Y/n]" -ForegroundColor Yellow
    Write-Host "       $Bg [Y/n]" -ForegroundColor Yellow
    $answer = [Console]::In.ReadLine()
    if ($null -eq $answer) { return $false }  # no input available -> treat as "no"
    $answer = $answer.Trim().ToLower()
    return ($answer -eq '' -or $answer -in @('y', 'yes', 'd', 'da', 'д', 'да'))
}

# ---------- system helpers ----------

function Test-Command([string]$Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Update-SessionPath {
    # Pick up PATH changes made by installers without reopening the terminal.
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machine;$user"
}

function Install-Package([string]$WingetId, [string]$Name, [string]$Url) {
    if (-not (Test-Command 'winget')) {
        Write-Fail "winget is not available. Install $Name manually: $Url" `
                   "winget липсва. Инсталирай $Name ръчно: $Url"
        return
    }
    if (-not (Confirm-Action "Install $Name now with winget?" "Да инсталирам ли $Name сега с winget?")) {
        return
    }
    # Start-Process keeps winget attached to this console so its own prompts (agreements, UAC) work.
    Start-Process -FilePath 'winget' -ArgumentList @('install', '--id', $WingetId, '--exact') -NoNewWindow -Wait
    Update-SessionPath
}

function Get-EnvValue([string]$Name) {
    if (-not (Test-Path -LiteralPath $EnvFile)) { return $null }
    foreach ($line in Get-Content -LiteralPath $EnvFile -Encoding UTF8) {
        if ($line -match "^\s*$Name\s*=\s*(.*)$") { return $Matches[1].Trim().Trim('"') }
    }
    return $null
}

# ---------- checks ----------

function Find-Python {
    # Returns the full path of a Python >= $MinPython, or $null.
    # Note: the Microsoft Store "python" alias fails here, which is what we want.
    foreach ($candidate in @(@('py', '-3'), @('python'), @('python3'))) {
        $exe   = $candidate[0]
        $extra = @($candidate | Select-Object -Skip 1)
        if (-not (Test-Command $exe)) { continue }
        try {
            $out = & $exe @extra -c "import sys; print(sys.executable); print('%d.%d' % sys.version_info[:2])" 2>$null
        } catch { continue }
        if ($LASTEXITCODE -ne 0) { continue }
        $lines = @($out)
        if ($lines.Count -lt 2) { continue }
        if ([version]$lines[1] -ge $MinPython) { return $lines[0] }
        Write-Warn "Found Python $($lines[1]), but $MinPython+ is required." `
                   "Намерен е Python $($lines[1]), но е нужен $MinPython+."
    }
    return $null
}

function Assert-Python {
    Write-Step 'Python' ''
    $python = Find-Python
    if (-not $python) {
        Write-Warn "Python $MinPython+ was not found." "Python $MinPython+ не е намерен."
        Install-Package 'Python.Python.3.13' 'Python 3.13' 'https://www.python.org/downloads/'
        $python = Find-Python
    }
    if (-not $python) {
        Write-Fail 'Python is required. Install it, reopen this window and try again.' `
                   'Python е задължителен. Инсталирай го, отвори прозореца наново и опитай пак.'
        exit 1
    }
    Write-Ok $python
    $script:Python = $python
}

function Test-Venv {
    if (-not (Test-Path -LiteralPath $VenvPy)) { return $false }
    & $VenvPy -c "import sys" 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Initialize-Venv([string]$Python) {
    Write-Step 'Virtual environment and libraries' 'Виртуална среда и библиотеки'

    if (-not (Test-Venv)) {
        if (Test-Path -LiteralPath $VenvDir) {
            Write-Warn 'The virtual environment is broken - recreating it.' 'Виртуалната среда е повредена - създавам я наново.'
            Remove-Item -LiteralPath $VenvDir -Recurse -Force
        }
        Write-Msg '   Creating .venv ...' '   Създавам .venv ...'
        & $Python -m venv $VenvDir
        if (-not (Test-Venv)) {
            Write-Fail 'Could not create the virtual environment.' 'Не успях да създам виртуалната среда.'
            exit 1
        }
    }

    $wanted = (Get-FileHash -LiteralPath $ReqFile -Algorithm SHA256).Hash
    $have   = if (Test-Path -LiteralPath $ReqStamp) { (Get-Content -LiteralPath $ReqStamp -Raw).Trim() } else { '' }
    if ($wanted -ne $have) {
        Write-Msg '   Installing libraries (first start or requirements.txt changed) ...' `
                  '   Инсталирам библиотеките (първо стартиране или променен requirements.txt) ...'
        & $VenvPy -m pip install --disable-pip-version-check -r $ReqFile
        if ($LASTEXITCODE -ne 0) {
            Write-Fail 'Installing the libraries failed. Check your internet connection and run again.' `
                       'Инсталацията на библиотеките се провали. Провери интернета и пусни отново.'
            exit 1
        }
        Set-Content -LiteralPath $ReqStamp -Value $wanted -Encoding ASCII
    }
    Write-Ok 'libraries installed / библиотеките са инсталирани'
}

function Assert-Node {
    Write-Step 'Node.js (used by yt-dlp for YouTube)' 'Node.js (yt-dlp го ползва за YouTube)'
    if (-not (Test-Command 'node')) {
        Write-Warn 'Node.js was not found.' 'Node.js не е намерен.'
        Install-Package 'OpenJS.NodeJS.LTS' 'Node.js LTS' 'https://nodejs.org/'
    }
    if (-not (Test-Command 'node')) {
        Write-Fail 'Node.js is required. Install it, reopen this window and try again.' `
                   'Node.js е задължителен. Инсталирай го, отвори прозореца наново и опитай пак.'
        exit 1
    }
    Write-Ok "node $(& node --version)"
}

function Test-Ffmpeg {
    $custom = Get-EnvValue 'FFMPEG_PATH'
    if ($custom -and $custom -ne 'ffmpeg') { return (Test-Path -LiteralPath $custom) }
    return (Test-Command 'ffmpeg')
}

function Assert-Ffmpeg {
    Write-Step 'FFmpeg (plays the audio)' 'FFmpeg (пуска звука)'
    if (-not (Test-Ffmpeg)) {
        $custom = Get-EnvValue 'FFMPEG_PATH'
        if ($custom -and $custom -ne 'ffmpeg') {
            Write-Fail "FFMPEG_PATH in .env points to a file that does not exist: $custom" `
                       "FFMPEG_PATH в .env сочи към несъществуващ файл: $custom"
            exit 1
        }
        Write-Warn 'FFmpeg was not found.' 'FFmpeg не е намерен.'
        Install-Package 'Gyan.FFmpeg' 'FFmpeg' 'https://www.gyan.dev/ffmpeg/builds/'
    }
    if (-not (Test-Ffmpeg)) {
        Write-Fail 'FFmpeg is required. Install it, reopen this window and try again.' `
                   'FFmpeg е задължителен. Инсталирай го, отвори прозореца наново и опитай пак.'
        exit 1
    }
    Write-Ok 'ffmpeg'
}

function Assert-Config {
    Write-Step 'Configuration (.env)' 'Настройки (.env)'
    if (-not (Test-Path -LiteralPath $EnvFile)) {
        Copy-Item -LiteralPath $EnvSample -Destination $EnvFile
        Write-Warn 'Created .env from .env.example.' 'Създадох .env от .env.example.'
    }
    if (-not (Get-EnvValue 'DISCORD_TOKEN')) {
        Write-Warn 'DISCORD_TOKEN in .env is empty (see README, step 2).' `
                   'DISCORD_TOKEN в .env е празен (виж README, стъпка 2).'
        if (Confirm-Action 'Open .env in Notepad now? Save and close it to continue.' `
                           'Да отворя ли .env в Notepad? Запази и затвори, за да продължим.') {
            Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$EnvFile`"" -Wait
        }
    }
    if (-not (Get-EnvValue 'DISCORD_TOKEN')) {
        Write-Fail 'Fill in DISCORD_TOKEN in .env and run again.' 'Попълни DISCORD_TOKEN в .env и пусни отново.'
        exit 1
    }
    Write-Ok '.env'
}

# ---------- main ----------

Write-Host 'IxMusicBot' -ForegroundColor Magenta
Assert-Python
Initialize-Venv $script:Python
Assert-Node
Assert-Ffmpeg
Assert-Config

$env:IXMUSIC_LAUNCHER = '1'  # lets the bot restart itself to apply yt-dlp updates
while ($true) {
    Write-Step 'Updating yt-dlp' 'Обновявам yt-dlp'
    & $VenvPy -m pip install -q --disable-pip-version-check -U 'yt-dlp[default]'
    if ($LASTEXITCODE -ne 0) {
        Write-Warn 'yt-dlp update failed - starting with the installed version.' `
                   'Обновяването на yt-dlp се провали - стартирам с инсталираната версия.'
    }

    Write-Step 'Starting the bot (Ctrl+C to stop)' 'Стартирам бота (Ctrl+C за спиране)'
    & $VenvPy (Join-Path $PSScriptRoot 'bot.py')
    $code = $LASTEXITCODE
    if ($code -eq $RestartExitCode) {
        Write-Msg 'Restarting to apply the yt-dlp update...' 'Рестартирам, за да приложа обновлението на yt-dlp...' 'Cyan'
        continue
    }
    Write-Msg "Bot stopped (exit code $code)." "Ботът спря (код $code)." 'Cyan'
    exit $code
}
