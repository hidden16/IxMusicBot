#Requires -Version 5.1
<#
    IxMusicBot launcher (started by run.bat).
    1. Checks Python, Node.js and FFmpeg and offers to install missing ones with winget (asks first).
    2. Creates / repairs the virtual environment and installs requirements when they change.
    3. Makes sure .env exists and has a token.
    4. Before every start, updates all libraries (within the versions requirements.txt allows) and checks
       them. If an update breaks them, or the bot crashes right after one, it goes back to the last set
       of versions that worked (.venv\known-good.txt) and skips updating until the next launch.
    5. Runs the bot and restarts it when it asks to (exit code 3) or when it crashes
       (waiting longer after each crash in a row).
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
$ConfigErrorExitCode = 2   # bad / missing token: restarting would not help
$KnownGood = Join-Path $VenvDir 'known-good.txt'  # pip freeze of the last versions that ran fine
$HealthySeconds = 120      # a bot that ran this long counts as working with its current libraries

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

# What each program is, where it comes from and where it goes. Shown before asking to install it.
$Packages = @{
    python = @{
        Id = 'Python.Python.3.13'; Name = 'Python 3.13'; Url = 'https://www.python.org/downloads/'
        Lines = @(
            @('Why:        runs the bot itself.',
              'Защо:       на него работи самият бот.'),
            @('From:       Python Software Foundation (python.org), license PSF-2.0.',
              'Откъде:     Python Software Foundation (python.org), лиценз PSF-2.0.'),
            @('Where:      usually %LOCALAPPDATA%\Programs\Python\Python313, added to PATH.',
              'Къде:       обикновено %LOCALAPPDATA%\Programs\Python\Python313, добавя се в PATH.'),
            @('Remove:     Settings -> Apps -> Python 3.13, or: winget uninstall --id Python.Python.3.13',
              'Премахване: Settings -> Apps -> Python 3.13, или: winget uninstall --id Python.Python.3.13')
        )
    }
    node = @{
        Id = 'OpenJS.NodeJS.LTS'; Name = 'Node.js LTS'; Url = 'https://nodejs.org/'
        Lines = @(
            @('Why:        yt-dlp needs a JavaScript runtime to read YouTube pages.',
              'Защо:       yt-dlp има нужда от JavaScript среда, за да чете страниците на YouTube.'),
            @('From:       OpenJS Foundation (nodejs.org), license MIT.',
              'Откъде:     OpenJS Foundation (nodejs.org), лиценз MIT.'),
            @('Where:      C:\Program Files\nodejs, added to PATH. Windows may ask for admin rights (UAC).',
              'Къде:       C:\Program Files\nodejs, добавя се в PATH. Windows може да поиска админ права (UAC).'),
            @('Remove:     Settings -> Apps -> Node.js, or: winget uninstall --id OpenJS.NodeJS.LTS',
              'Премахване: Settings -> Apps -> Node.js, или: winget uninstall --id OpenJS.NodeJS.LTS')
        )
    }
    ffmpeg = @{
        Id = 'Gyan.FFmpeg'; Name = 'FFmpeg'; Url = 'https://www.gyan.dev/ffmpeg/builds/'
        Lines = @(
            @('Why:        converts the YouTube audio into sound Discord can play.',
              'Защо:       превръща аудиото от YouTube в звук, който Discord може да пусне.'),
            @('From:       gyan.dev builds (linked from ffmpeg.org), license GPL-3.0.',
              'Откъде:     компилациите на gyan.dev (с линк от ffmpeg.org), лиценз GPL-3.0.'),
            @('Where:      %LOCALAPPDATA%\Microsoft\WinGet\Packages, command added via WinGet\Links. No admin rights.',
              'Къде:       %LOCALAPPDATA%\Microsoft\WinGet\Packages, командата се добавя през WinGet\Links. Без админ права.'),
            @('Remove:     winget uninstall --id Gyan.FFmpeg',
              'Премахване: winget uninstall --id Gyan.FFmpeg')
        )
    }
}

function Show-Package([hashtable]$Package) {
    Write-Host ''
    Write-Host "   $($Package.Name)  (winget: $($Package.Id))" -ForegroundColor White
    foreach ($pair in $Package.Lines) {
        Write-Host "     $($pair[0])"
        Write-Host "     $($pair[1])" -ForegroundColor DarkGray
    }
    Write-Host ''
}

function Install-Package([string]$Key) {
    $p = $Packages[$Key]
    if (-not (Test-Command 'winget')) {
        Write-Fail "winget is not available. Install $($p.Name) manually: $($p.Url)" `
                   "winget липсва. Инсталирай $($p.Name) ръчно: $($p.Url)"
        return
    }
    Show-Package $p
    if (-not (Confirm-Action "Install $($p.Name) now with winget?" "Да инсталирам ли $($p.Name) сега с winget?")) {
        return
    }
    # Start-Process keeps winget attached to this console so its own prompts (agreements, UAC) work.
    Start-Process -FilePath 'winget' -ArgumentList @('install', '--id', $p.Id, '--exact') -NoNewWindow -Wait
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
        Install-Package 'python'
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
        Write-Msg '   They go only into the .venv folder here (~70 MB): discord.py, yt-dlp, python-dotenv and their dependencies.' `
                  '   Слагат се само в папката .venv тук (~70 MB): discord.py, yt-dlp, python-dotenv и техните зависимости.' 'DarkGray'
        Write-Msg '   Nothing is installed system-wide. To remove them, delete the .venv folder.' `
                  '   Нищо не се инсталира в системата. За да ги премахнеш, изтрий папката .venv.' 'DarkGray'
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
        Install-Package 'node'
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
        Install-Package 'ffmpeg'
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

# ---------- updates ----------

$script:HoldUpdates = $false

function Get-Freeze {
    return @(& $VenvPy -m pip freeze --disable-pip-version-check 2>$null)
}

function Test-Libraries {
    # 1. dependencies are consistent; 2. every installed version is inside the limits in requirements.txt
    #    (e.g. davey<0.2, without which audio goes silent); 3. voice support (PyNaCl, davey/DAVE) loads.
    & $VenvPy -m pip check --disable-pip-version-check 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { return $false }
    # No double quotes in this code: Windows PowerShell 5.1 mangles them in native arguments.
    $problems = & $VenvPy -c @'
import sys
from importlib.metadata import PackageNotFoundError, version
try:
    from packaging.requirements import Requirement
except ImportError:
    from pip._vendor.packaging.requirements import Requirement
bad = []
for line in open(sys.argv[1], encoding='utf-8'):
    line = line.split('#', 1)[0].strip()
    if not line:
        continue
    req = Requirement(line)
    try:
        have = version(req.name)
    except PackageNotFoundError:
        bad.append(req.name + ' is missing')
        continue
    if not req.specifier.contains(have, prereleases=True):
        bad.append(req.name + ' ' + have + ' is outside ' + str(req.specifier))
try:
    import aiohttp, dotenv, yt_dlp
    from discord.voice_client import has_nacl
    from discord.voice_state import has_dave
    if not (has_nacl and has_dave):
        bad.append('voice support does not load (PyNaCl / davey)')
except Exception as e:
    bad.append('import failed: ' + repr(e))
print('\n'.join(bad))
raise SystemExit(1 if bad else 0)
'@ $ReqFile 2>$null
    $ok = ($LASTEXITCODE -eq 0)
    foreach ($p in @($problems | Where-Object { $_ })) { Write-Host "       $p" -ForegroundColor Yellow }
    return $ok
}

function Save-KnownGood {
    $freeze = Get-Freeze
    if ($freeze.Count -gt 0) { Set-Content -LiteralPath $KnownGood -Value $freeze -Encoding ASCII }
}

function Restore-KnownGood {
    Write-Msg '   Restoring the last working versions (.venv\known-good.txt) ...' `
              '   Връщам последните работещи версии (.venv\known-good.txt) ...'
    & $VenvPy -m pip install -q --disable-pip-version-check -r $KnownGood
    $ok = ($LASTEXITCODE -eq 0) -and (Test-Libraries)
    if ($ok) {
        Write-Ok 'restored / върнати'
        # Don't install the same broken versions again on the next restart of this launch.
        $script:HoldUpdates = $true
        $env:IXMUSIC_HOLD_UPDATES = '1'
    } else {
        Write-Fail 'Could not restore the previous versions.' 'Не успях да върна предишните версии.'
    }
    return $ok
}

function Update-Libraries {
    # Updates everything in requirements.txt as far as its version limits allow.
    # Returns $true when something changed.
    Write-Step 'Updating libraries' 'Обновявам библиотеките'
    $before = Get-Freeze
    & $VenvPy -m pip install -q --disable-pip-version-check -U -r $ReqFile
    if ($LASTEXITCODE -ne 0) {
        Write-Warn 'Update failed (no internet?) - starting with the installed versions.' `
                   'Обновяването се провали (няма интернет?) - стартирам с инсталираните версии.'
    }
    $changed = @(Get-Freeze | Where-Object { $before -notcontains $_ })
    if ($changed.Count -eq 0) {
        Write-Ok 'everything is up to date / всичко е актуално'
    } else {
        foreach ($line in $changed) { Write-Ok "updated / обновено: $line" }
    }

    if (Test-Libraries) { return ($changed.Count -gt 0) }

    Write-Warn 'The libraries fail the check (dependency conflict or voice support missing).' `
               'Библиотеките не минават проверката (конфликт на версии или липсва поддръжка на глас).'
    if ((Test-Path -LiteralPath $KnownGood) -and (Restore-KnownGood)) { return $false }
    Write-Fail 'Delete the .venv folder and run run.bat again to reinstall everything.' `
               'Изтрий папката .venv и пусни run.bat отново, за да се преинсталира всичко.'
    exit 1
}

# ---------- main ----------

# Only one copy per folder: two bots on one token would both answer every command.
$mutexName = 'Local\IxMusicBot-' + ((Get-FileHash -InputStream ([IO.MemoryStream]::new(
    [Text.Encoding]::UTF8.GetBytes($PSScriptRoot.ToLowerInvariant()))) -Algorithm SHA256).Hash.Substring(0, 16))
$script:Mutex = New-Object System.Threading.Mutex($false, $mutexName)
$owned = $false
try { $owned = $script:Mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) {
    Write-Fail 'IxMusicBot is already running in another window. Close that one first.' `
               'IxMusicBot вече работи в друг прозорец. Първо затвори него.'
    exit 1
}

Write-Host 'IxMusicBot' -ForegroundColor Magenta
Write-Msg 'This launcher checks Python, Node.js and FFmpeg. If one is missing, it explains what it is and asks before installing it.' `
          'Този стартер проверява Python, Node.js и FFmpeg. Ако нещо липсва, обяснява какво е и пита преди да го инсталира.' 'DarkGray'
Write-Msg 'Details: README.md -> "What gets installed".' 'Подробности: README.bg.md -> "Какво се инсталира".' 'DarkGray'
Assert-Python
Initialize-Venv $script:Python
Assert-Node
Assert-Ffmpeg
Assert-Config

$env:IXMUSIC_LAUNCHER = '1'  # lets the bot restart itself to apply yt-dlp updates
$crashes = 0
while ($true) {
    $updated = $false
    if ((Get-EnvValue 'AUTO_UPDATE') -in @('0', 'false', 'no', 'off')) {
        Write-Step 'Updates are off (AUTO_UPDATE=false in .env)' 'Обновяването е изключено (AUTO_UPDATE=false в .env)'
    } elseif ($script:HoldUpdates) {
        Write-Step 'Updates paused (the last one was rolled back) until run.bat is started again' `
                   'Обновленията са спрени (последното беше върнато) до следващото пускане на run.bat'
    } else {
        $updated = Update-Libraries
    }

    Write-Step 'Starting the bot (Ctrl+C to stop)' 'Стартирам бота (Ctrl+C за спиране)'
    $startedAt = Get-Date
    $proc = Start-Process -FilePath $VenvPy -ArgumentList "`"$(Join-Path $PSScriptRoot 'bot.py')`"" `
                          -WorkingDirectory $PSScriptRoot -NoNewWindow -PassThru
    $null = $proc.Handle  # needed for ExitCode to be filled in later
    $ranLong = -not $proc.WaitForExit($HealthySeconds * 1000)
    if ($ranLong) {
        Save-KnownGood  # these versions work: the fallback for the next broken update
        $proc.WaitForExit()
    }
    $code = $proc.ExitCode
    if ($code -eq $RestartExitCode) {
        Write-Msg 'Restarting to apply the yt-dlp update...' 'Рестартирам, за да приложа обновлението на yt-dlp...' 'Cyan'
        continue
    }
    if ($code -eq 0 -or $code -eq $ConfigErrorExitCode) {
        Write-Msg "Bot stopped (exit code $code)." "Ботът спря (код $code)." 'Cyan'
        exit $code
    }

    # Crashed right after an update: the update is the likely cause, so go back to what worked.
    if ($updated -and -not $ranLong -and (Test-Path -LiteralPath $KnownGood)) {
        Write-Warn "Bot crashed (exit code $code) right after an update - going back to the last working versions." `
                   "Ботът гръмна (код $code) веднага след обновяване - връщам последните работещи версии."
        if (Restore-KnownGood) { continue }
    }

    # A crash: start again. A bot that ran for a while starts over at the shortest wait.
    if (((Get-Date) - $startedAt).TotalMinutes -ge 10) { $crashes = 0 }
    $crashes++
    $wait = [Math]::Min(300, 10 * [Math]::Pow(2, $crashes - 1))
    Write-Warn "Bot crashed (exit code $code). Starting again in $wait s... (Ctrl+C to stop)" `
               "Ботът гръмна (код $code). Пускам го пак след $wait с... (Ctrl+C за спиране)"
    Start-Sleep -Seconds $wait
}
