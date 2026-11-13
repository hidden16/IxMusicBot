import os

from dotenv import load_dotenv

load_dotenv()


def _int(name: str, default: int) -> int:
    value = os.getenv(name, "").strip()
    return int(value) if value else default


DISCORD_TOKEN = os.getenv("DISCORD_TOKEN", "").strip()
GUILD_ID = _int("GUILD_ID", 0) or None
MUSIC_CHANNEL_ID = _int("MUSIC_CHANNEL_ID", 0) or None
ALLOWED_USER_IDS = {
    int(x) for x in os.getenv("ALLOWED_USER_IDS", "").replace(" ", "").split(",") if x
}
LANGUAGE = os.getenv("LANGUAGE", "auto").strip().lower() or "auto"  # auto | bg | en
FFMPEG_PATH =os.getenv("FFMPEG_PATH", "").strip() or "ffmpeg"
DEFAULT_VOLUME = max(0, min(100, _int("DEFAULT_VOLUME", 50)))
IDLE_TIMEOUT = _int("IDLE_TIMEOUT", 300)
MAX_QUEUE = max(1, _int("MAX_QUEUE", 100))
AUTO_UPDATE = os.getenv("AUTO_UPDATE", "true").strip().lower() not in ("0", "false", "no", "off")
UPDATE_CHECK_HOURS = max(1, _int("UPDATE_CHECK_HOURS", 24))
