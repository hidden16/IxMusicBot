"""Bot texts in English and Bulgarian.

LANGUAGE=auto replies in the language of the user's Discord client (Bulgarian -> bg, anything else -> en).
LANGUAGE=bg / LANGUAGE=en forces one language.
"""

from __future__ import annotations

import discord
from discord import app_commands

import config

STRINGS: dict[str, dict[str, str]] = {
    "en": {
        "guild_only": "Commands only work in a server.",
        "no_access": "You don't have access to this bot.",
        "use_music_channel": "🎵 Use {channel} for music commands.",
        "idle_leave": "No music for a while — leaving. 👋",
        "everyone_left": "Everyone left — stopping. 👋",
        "load_failed": "⚠️ Couldn't load {link}: `{error}`",
        "nothing_playing": "Nothing is playing right now.",
        "np_title": "🎶 Now playing",
        "field_duration": "Duration",
        "field_requested_by": "Requested by",
        "field_in_queue": "In queue",
        "live": "live / ?",
        "join_voice_first": "Join a voice channel first.",
        "not_in_voice": "I'm not in a voice channel.",
        "empty_query": "Empty search.",
        "only_youtube": "Only YouTube and YouTube Music links are supported.",
        "queue_full": "⚠️ The queue is full (max {max} songs).",
        "not_found": "⚠️ Nothing found: `{error}`",
        "no_results": "⚠️ No results.",
        "added": "➕ Added to queue (#{pos}): {link} `{duration}`",
        "loading": "▶️ Loading {link}",
        "paused": "⏸️ Paused.",
        "resumed": "▶️ Resumed.",
        "not_paused": "Not paused.",
        "skipped": "⏭️ Skipped.",
        "stopped": "⏹️ Stopped and cleared the queue.",
        "bye": "👋 Bye!",
        "queue_title": "📜 Queue",
        "queue_now": "**Now:**",
        "queue_more": "… and {n} more",
        "queue_empty": "The queue is empty.",
        "volume_set": "🔊 Volume: **{level}%**",
        "no_such_position": "There's no such number in the queue.",
        "removed": "🗑️ Removed: {link}",
    },
    "bg": {
        "guild_only": "Командите работят само в сървър.",
        "no_access": "Нямаш достъп до този бот.",
        "use_music_channel": "🎵 Използвай {channel} за музикалните команди.",
        "idle_leave": "Няма музика от известно време — излизам. 👋",
        "everyone_left": "Всички излязоха — спирам. 👋",
        "load_failed": "⚠️ Не успях да заредя {link}: `{error}`",
        "nothing_playing": "Нищо не свири в момента.",
        "np_title": "🎶 Сега свири",
        "field_duration": "Времетраене",
        "field_requested_by": "Пуснато от",
        "field_in_queue": "В опашката",
        "live": "на живо / ?",
        "join_voice_first": "Първо влез в гласов канал.",
        "not_in_voice": "Не съм в гласов канал.",
        "empty_query": "Празно търсене.",
        "only_youtube": "Поддържат се само линкове от YouTube и YouTube Music.",
        "queue_full": "⚠️ Опашката е пълна (максимум {max} песни).",
        "not_found": "⚠️ Не намерих нищо: `{error}`",
        "no_results": "⚠️ Няма резултати.",
        "added": "➕ Добавено в опашката (#{pos}): {link} `{duration}`",
        "loading": "▶️ Зареждам {link}",
        "paused": "⏸️ Пауза.",
        "resumed": "▶️ Продължавам.",
        "not_paused": "Не е на пауза.",
        "skipped": "⏭️ Прескочено.",
        "stopped": "⏹️ Спрях и изчистих опашката.",
        "bye": "👋 Чао!",
        "queue_title": "📜 Опашка",
        "queue_now": "**Сега:**",
        "queue_more": "… и още {n}",
        "queue_empty": "Опашката е празна.",
        "volume_set": "🔊 Сила на звука: **{level}%**",
        "no_such_position": "Няма такъв номер в опашката.",
        "removed": "🗑️ Премахнато: {link}",
    },
}

# Slash command / option descriptions: English is the default in code, Bulgarian is shown
# automatically to users whose Discord client is set to Bulgarian.
COMMAND_DESCRIPTIONS_BG: dict[str, str] = {
    "Play a song from YouTube / YouTube Music (link or search)": "Пусни песен от YouTube / YouTube Music (линк или търсене)",
    "Video link or search text": "Линк към видео или текст за търсене",
    "Pause playback": "Пауза",
    "Resume playback": "Продължи след пауза",
    "Skip to the next song": "Следваща песен",
    "Stop the music and clear the queue": "Спри музиката и изчисти опашката",
    "Leave the voice channel": "Излез от гласовия канал",
    "Show the queue": "Покажи опашката",
    "Show what's playing now": "Какво свири в момента",
    "Set the volume (0-100)": "Сила на звука (0-100)",
    "0 to 100": "0 до 100",
    "Remove a song from the queue by number": "Премахни песен от опашката по номер",
    "Number from /queue": "Номер от /queue",
}


def lang_for(locale: discord.Locale | str | None) -> str:
    if config.LANGUAGE in STRINGS:
        return config.LANGUAGE
    return "bg" if str(locale or "").lower().startswith("bg") else "en"


def t(key: str, locale: discord.Locale | str | None = None, **kwargs) -> str:
    lang = lang_for(locale)
    text = STRINGS[lang].get(key) or STRINGS["en"][key]
    return text.format(**kwargs) if kwargs else text


class BotTranslator(app_commands.Translator):
    _DESCRIPTION_LOCATIONS = (
        app_commands.TranslationContextLocation.command_description,
        app_commands.TranslationContextLocation.parameter_description,
    )

    async def translate(
        self,
        string: app_commands.locale_str,
        locale: discord.Locale,
        context: app_commands.TranslationContextTypes,
    ) -> str | None:
        if locale is discord.Locale.bulgarian and context.location in self._DESCRIPTION_LOCATIONS:
            return COMMAND_DESCRIPTIONS_BG.get(string.message)
        return None
