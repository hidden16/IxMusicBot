# IxMusicBot

**English** | [Български](README.bg.md)

A personal Discord music bot that plays audio from YouTube / YouTube Music in a voice channel.
Python + [discord.py](https://github.com/Rapptz/discord.py) + [yt-dlp](https://github.com/yt-dlp/yt-dlp) + FFmpeg.

> ⚠️ **Disclaimer**
>
> This project is intended for personal and educational use only. It is not affiliated with,
> endorsed by, or sponsored by YouTube, Google, or Discord. All trademarks belong to their
> respective owners. This project does not host or distribute any copyrighted content.
> Anyone running this bot is solely responsible for complying with the
> [YouTube Terms of Service](https://www.youtube.com/t/terms),
> the [Discord Terms of Service](https://discord.com/terms),
> the [Discord Developer Policy](https://discord.com/developers/docs/policies-and-agreements/developer-policy),
> and applicable law.

## Commands

| Command | What it does |
|---|---|
| `/play <link or search>` | Plays a song or adds it to the queue |
| `/pause`, `/resume` | Pause / resume |
| `/skip` | Next song |
| `/stop` | Stops and clears the queue |
| `/queue` | Shows the queue |
| `/nowplaying` | What's playing now |
| `/volume <0-100>` | Volume |
| `/remove <number>` | Removes a song from the queue |
| `/leave` | Leaves the voice channel |

The bot leaves on its own after `IDLE_TIMEOUT` seconds without music, or when everyone leaves the channel.

## Music channel
Set `MUSIC_CHANNEL_ID` to keep the bot in one text channel. Music commands then work only there
(anywhere else the user gets a private hint pointing to the channel), and "Now playing" messages stay out of other chats.

1. Create a text channel yourself, e.g. `#music`. The bot does not create channels, so it never needs
   the risky **Manage Channels** / **Manage Roles** permissions.
2. If the channel is private, add the bot to it with View Channel, Send Messages and Embed Links.
3. Right-click the channel → **Copy Channel ID** → paste it into `.env` → `MUSIC_CHANNEL_ID`.

On start, the console warns if the channel can't be found or the bot is missing permissions there.
Leave `MUSIC_CHANNEL_ID` empty to allow commands in every channel. Who may use the bot is still controlled by `ALLOWED_USER_IDS`.

## Languages
The bot speaks English and Bulgarian. With `LANGUAGE=auto` (default), each user gets replies and
command descriptions in their Discord client's language (Bulgarian → Bulgarian, anything else → English).
Set `LANGUAGE=en` or `LANGUAGE=bg` in `.env` to force one language.

## Security
- `/play` only accepts YouTube / YouTube Music links or search text. All other URLs are rejected.
- The queue is limited to `MAX_QUEUE` songs (default 100). A playlist link only loads its first video.
- The bot never pings anyone (`@everyone`, roles, users).
- Use `ALLOWED_USER_IDS` to limit who can use the bot.
- Never give the bot **Administrator** permission. If the token leaks: Developer Portal → Bot → **Reset Token**.

## Installation

### 1. Requirements
- Python 3.11+
- Node.js (used by yt-dlp to handle YouTube)
- FFmpeg (plays the audio). If it is not in PATH, set the full path in `.env` → `FFMPEG_PATH`.

You don't have to install them by hand: `run.bat` checks all three on every start and, if one is missing,
offers to install it with `winget` (it asks before each install). See [What gets installed](#what-gets-installed). Manual install:
```
winget install Python.Python.3.13
winget install OpenJS.NodeJS.LTS
winget install Gyan.FFmpeg
```

### 2. Create a Discord application
1. Go to https://discord.com/developers/applications → **New Application** → give it a name → **Create**.
2. **Bot** → **Reset Token** → copy the token. Never share it or upload it to GitHub.
3. Privileged Gateway Intents are not needed. Leave them off.
4. For a private bot: **Installation** → *Install Link* → **None** → Save, then
   **Bot** → turn off **Public Bot** → Save. Only you can add it to servers this way.

### 3. Configuration
Copy `.env.example` to `.env` and fill in:
- `DISCORD_TOKEN`: the token from step 2.
- `GUILD_ID`: your server ID. Enable *User Settings → Advanced → Developer Mode*, then
  right-click the server icon → **Copy Server ID**.
- Optional `MUSIC_CHANNEL_ID`: right-click a channel → **Copy Channel ID** (see [Music channel](#music-channel)).
- Optional `ALLOWED_USER_IDS`: right-click a user's name → **Copy User ID** (a 17–19 digit number).

### 4. Start
Double-click `run.bat`, or:
```
.venv\Scripts\python.exe bot.py
```
`run.bat` (via `start.ps1`) does everything needed before starting the bot:
1. checks Python, Node.js and FFmpeg and offers to install missing ones;
2. creates the virtual environment (or recreates it if it is broken) and installs the libraries
   on first start, after a failed install, or when `requirements.txt` changes;
3. creates `.env` if it is missing and offers to open it in Notepad if the token is empty;
4. updates yt-dlp and starts the bot.

### 5. Add the bot to your server
On start, the bot prints an **invite link** with the required permissions to the console.
Open it, choose your server, and click **Authorize**.

Or build it manually, replacing `APP_ID` with the *Application ID* from **General Information**:
```
https://discord.com/oauth2/authorize?client_id=APP_ID&scope=bot+applications.commands&permissions=3165184
```
Permissions: View Channels, Send Messages, Embed Links, Connect, Speak.

### 6. Usage
Join a voice channel and type `/play` with a song name or a YouTube / YouTube Music link.
The bot only runs while `bot.py` is running on your machine.

## What gets installed
`run.bat` never installs anything silently. For each missing program it first shows what it is, where it
comes from and where it will go, then asks `[Y/n]`. If you answer **n**, nothing is installed and the
launcher stops with a message. Installs use [winget](https://learn.microsoft.com/windows/package-manager/winget/),
Windows' built-in package manager, which downloads each program from its official source.

| Program | Why the bot needs it | Source and license | Where it goes | How to remove |
|---|---|---|---|---|
| **Python 3.13** (only if Python 3.11+ is missing) | Runs the bot | python.org, PSF-2.0 | Usually `%LOCALAPPDATA%\Programs\Python\Python313`, added to PATH | Settings → Apps → Python 3.13, or `winget uninstall --id Python.Python.3.13` |
| **Node.js LTS** | yt-dlp uses it to read YouTube pages | nodejs.org, MIT | `C:\Program Files\nodejs`, added to PATH. Windows may ask for admin rights (UAC) | Settings → Apps → Node.js, or `winget uninstall --id OpenJS.NodeJS.LTS` |
| **FFmpeg** | Turns YouTube audio into sound Discord can play | gyan.dev builds (linked from ffmpeg.org), GPL-3.0 | `%LOCALAPPDATA%\Microsoft\WinGet\Packages`, command added via `WinGet\Links`. No admin rights | `winget uninstall --id Gyan.FFmpeg` |

winget itself may show the program's license or source agreement and ask you to accept it. That prompt comes
from winget, not from the bot.

**Python libraries** are installed without asking, but only inside the project's `.venv` folder (~70 MB):
discord.py (with voice support), yt-dlp, python-dotenv and their dependencies. Nothing is installed
system-wide; delete `.venv` to remove them. yt-dlp in `.venv` is updated on every start (see below).

The launcher does **not** create services, scheduled tasks or autostart entries, and does not change any
other system settings. The bot runs only while the `run.bat` window is open.

## Updating yt-dlp
YouTube changes often, so yt-dlp must stay up to date. When the bot is started with `run.bat`, this is automatic:
- on every start, `run.bat` updates yt-dlp first;
- every `UPDATE_CHECK_HOURS` hours (default 24), the bot checks PyPI for a new version. If there is one,
  it waits until no music is playing anywhere, restarts, and `run.bat` installs it.

Only yt-dlp is updated. Other libraries stay on their versions so nothing breaks unexpectedly.
Turn it off with `AUTO_UPDATE=false` in `.env`. Manual update:
```
.venv\Scripts\python.exe -m pip install -U "yt-dlp[default]"
```

## Project structure
```
bot.py           – startup, loads cogs, syncs slash commands
config.py        – reads .env
i18n.py          – English / Bulgarian texts
cogs/music.py    – queue, player and all music commands
cogs/updater.py  – automatic yt-dlp update check
run.bat          – double-click launcher
start.ps1        – prerequisite checks, setup and restart loop
```

## License
[MIT](LICENSE)
