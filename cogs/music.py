from __future__ import annotations

import asyncio
import functools
import logging
import re
import time
from collections import deque
from dataclasses import dataclass
from urllib.parse import urlparse

import discord
import yt_dlp
from discord import app_commands
from discord.app_commands import locale_str as _
from discord.ext import commands

import config
from i18n import t

log = logging.getLogger("ixmusic.music")

YTDL_OPTS = {
    "format": "bestaudio/best",
    "noplaylist": True,
    "playlist_items": "1",  # a playlist link only ever loads its first video
    "quiet": True,
    "no_warnings": True,
    "source_address": "0.0.0.0",
    # Only YouTube extractors: no generic fallback that would fetch arbitrary URLs.
    "allowed_extractors": ["youtube", "youtube:.*"],
    # YouTube needs a JS runtime for its signature challenges; Node is already installed.
    "js_runtimes": {"node": {}},
}
FFMPEG_BEFORE = "-reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 -nostdin"
FFMPEG_OPTS = "-vn"
STREAM_URL_MAX_AGE = 30 * 60  # googlevideo URLs expire; re-resolve after 30 min

ALLOWED_HOSTS = ("youtube.com", "youtu.be")
_BARE_YT_URL = re.compile(r"^(?:[a-z0-9-]+\.)*(?:youtube\.com|youtu\.be)/", re.IGNORECASE)

Locale = discord.Locale | str | None


class QueryError(ValueError):
    """Raised with an i18n key as its message."""

    @property
    def key(self) -> str:
        return str(self.args[0])


def build_query(text: str) -> str:
    """Return a YouTube URL or a ytsearch query. Any non-YouTube link is rejected."""
    text = text.strip()
    if not text:
        raise QueryError("empty_query")

    candidate = None
    if "://" in text:
        candidate = text
    elif _BARE_YT_URL.match(text):
        candidate = "https://" + text

    if candidate is None:
        return f"ytsearch1:{text}"

    parsed = urlparse(candidate)
    host = (parsed.hostname or "").lower()
    if parsed.scheme in ("http", "https") and any(
        host == h or host.endswith("." + h) for h in ALLOWED_HOSTS
    ):
        return candidate
    raise QueryError("only_youtube")


def short_error(e: Exception, limit: int = 300) -> str:
    msg = str(e).replace("`", "'")
    return msg if len(msg) <= limit else msg[:limit] + "…"


def _extract(query: str) -> dict:
    with yt_dlp.YoutubeDL(YTDL_OPTS) as ydl:
        info = ydl.extract_info(query, download=False)
    if info and "entries" in info:
        entries = [e for e in info["entries"] if e]
        if not entries:
            raise LookupError("No results.")
        info = entries[0]
    if not info:
        raise LookupError("No results.")
    return info


async def extract(query: str) -> dict:
    loop = asyncio.get_running_loop()
    return await loop.run_in_executor(None, functools.partial(_extract, query))


def fmt_duration(seconds: int | None, locale: Locale = None) -> str:
    if not seconds:
        return t("live", locale)
    m, s = divmod(int(seconds), 60)
    h, m = divmod(m, 60)
    return f"{h}:{m:02}:{s:02}" if h else f"{m}:{s:02}"


@dataclass
class Track:
    title: str
    webpage_url: str
    duration: int | None
    thumbnail: str | None
    requester: str
    stream_url: str | None = None
    resolved_at: float = 0.0

    @classmethod
    def from_info(cls, info: dict, requester: str) -> Track:
        return cls(
            title=info.get("title") or "Untitled",
            webpage_url=info.get("webpage_url") or info.get("original_url") or "",
            duration=info.get("duration"),
            thumbnail=info.get("thumbnail"),
            requester=requester,
            stream_url=info.get("url"),
            resolved_at=time.monotonic(),
        )

    async def get_stream_url(self) -> str:
        if not self.stream_url or time.monotonic() - self.resolved_at > STREAM_URL_MAX_AGE:
            info = await extract(self.webpage_url)
            self.stream_url = info["url"]
            self.resolved_at = time.monotonic()
        return self.stream_url

    @property
    def link(self) -> str:
        title = discord.utils.escape_markdown(self.title).replace("[", "(").replace("]", ")")
        return f"[{title}]({self.webpage_url})"


class GuildPlayer:
    """Per-guild queue + playback loop."""

    def __init__(
        self, cog: Music, guild: discord.Guild, channel: discord.abc.Messageable, locale: Locale
    ):
        self.cog = cog
        self.bot = cog.bot
        self.guild = guild
        self.channel = channel
        self.locale = locale  # language for messages the bot posts on its own
        self.queue: deque[Track] = deque()
        self.current: Track | None = None
        self.volume = config.DEFAULT_VOLUME / 100
        self._wake = asyncio.Event()
        self._done = asyncio.Event()
        self._task = asyncio.create_task(self._run())

    def add(self, track: Track) -> None:
        self.queue.append(track)
        self._wake.set()

    def destroy(self) -> None:
        self._task.cancel()

    async def say(self, content: str | None = None, **kwargs) -> None:
        try:
            await self.channel.send(content, **kwargs)
        except discord.HTTPException:
            pass

    async def _run(self) -> None:
        loop = asyncio.get_running_loop()
        try:
            while True:
                if not self.queue:
                    self._wake.clear()
                    try:
                        await asyncio.wait_for(self._wake.wait(), timeout=config.IDLE_TIMEOUT)
                    except asyncio.TimeoutError:
                        await self.say(t("idle_leave", self.locale))
                        return
                    continue

                vc = self.guild.voice_client
                if not isinstance(vc, discord.VoiceClient) or not vc.is_connected():
                    return

                track = self.queue.popleft()
                try:
                    stream_url = await track.get_stream_url()
                except Exception as e:  # noqa: BLE001
                    log.exception("Failed to resolve %s", track.webpage_url)
                    await self.say(t("load_failed", self.locale, link=track.link, error=short_error(e)))
                    continue

                source = discord.PCMVolumeTransformer(
                    discord.FFmpegPCMAudio(
                        stream_url,
                        executable=config.FFMPEG_PATH,
                        before_options=FFMPEG_BEFORE,
                        options=FFMPEG_OPTS,
                    ),
                    volume=self.volume,
                )

                def _after(error: Exception | None) -> None:
                    if error:
                        log.error("Player error: %s", error)
                    loop.call_soon_threadsafe(self._done.set)

                self._done.clear()
                self.current = track
                vc.play(source, after=_after)
                await self.say(embed=self.cog.now_playing_embed(self, self.locale))
                await self._done.wait()
                self.current = None
        except asyncio.CancelledError:
            pass
        finally:
            self.current = None
            self.queue.clear()
            vc = self.guild.voice_client
            if vc:
                try:
                    await vc.disconnect(force=True)
                except Exception:  # noqa: BLE001
                    pass
            self.cog.players.pop(self.guild.id, None)


class Music(commands.Cog):
    def __init__(self, bot: commands.Bot):
        self.bot = bot
        self.players: dict[int, GuildPlayer] = {}

    async def cog_unload(self) -> None:
        for player in list(self.players.values()):
            player.destroy()

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.guild is None:
            await interaction.response.send_message(t("guild_only", interaction.locale), ephemeral=True)
            return False
        if config.ALLOWED_USER_IDS and interaction.user.id not in config.ALLOWED_USER_IDS:
            await interaction.response.send_message(t("no_access", interaction.locale), ephemeral=True)
            return False
        music_channel = self._music_channel(interaction.guild_id)
        if music_channel is not None and interaction.channel_id != music_channel.id:
            await interaction.response.send_message(
                t("use_music_channel", interaction.locale, channel=music_channel.mention), ephemeral=True
            )
            return False
        return True

    def _music_channel(self, guild_id: int | None) -> discord.abc.GuildChannel | None:
        """The configured music channel, but only for the server it belongs to."""
        if not config.MUSIC_CHANNEL_ID:
            return None
        channel = self.bot.get_channel(config.MUSIC_CHANNEL_ID)
        if isinstance(channel, discord.abc.GuildChannel) and channel.guild.id == guild_id:
            return channel
        return None

    @commands.Cog.listener()
    async def on_ready(self) -> None:
        if not config.MUSIC_CHANNEL_ID:
            return
        channel = self.bot.get_channel(config.MUSIC_CHANNEL_ID)
        if not isinstance(channel, discord.abc.GuildChannel):
            log.warning(
                "MUSIC_CHANNEL_ID=%s was not found (wrong ID, or the bot can't see the channel). "
                "Commands will work in every channel.",
                config.MUSIC_CHANNEL_ID,
            )
            return
        perms = channel.permissions_for(channel.guild.me)
        missing = [
            name
            for name in ("view_channel", "send_messages", "embed_links")
            if not getattr(perms, name)
        ]
        if missing:
            log.warning("The bot is missing permissions in #%s: %s", channel.name, ", ".join(missing))
        else:
            log.info("Music commands are limited to #%s in %s", channel.name, channel.guild.name)

    # ---------- helpers ----------

    def now_playing_embed(self, player: GuildPlayer, locale: Locale) -> discord.Embed:
        track = player.current
        embed = discord.Embed(color=discord.Color.red())
        if track is None:
            embed.description = t("nothing_playing", locale)
            return embed
        embed.title = t("np_title", locale)
        embed.description = track.link
        embed.add_field(name=t("field_duration", locale), value=fmt_duration(track.duration, locale))
        embed.add_field(name=t("field_requested_by", locale), value=track.requester)
        embed.add_field(name=t("field_in_queue", locale), value=str(len(player.queue)))
        if track.thumbnail:
            embed.set_thumbnail(url=track.thumbnail)
        return embed

    async def _connect(self, interaction: discord.Interaction) -> discord.VoiceClient | None:
        member = interaction.user
        if not isinstance(member, discord.Member) or not member.voice or not member.voice.channel:
            await self._reply(interaction, t("join_voice_first", interaction.locale), ephemeral=True)
            return None
        channel = member.voice.channel
        vc = interaction.guild.voice_client
        if isinstance(vc, discord.VoiceClient) and vc.is_connected():
            if vc.channel != channel:
                await vc.move_to(channel)
            return vc
        return await channel.connect(self_deaf=True)

    def _player(self, interaction: discord.Interaction) -> GuildPlayer | None:
        return self.players.get(interaction.guild_id)

    @staticmethod
    async def _reply(interaction: discord.Interaction, content: str | None = None, **kwargs) -> None:
        if interaction.response.is_done():
            await interaction.followup.send(content, **kwargs)
        else:
            await interaction.response.send_message(content, **kwargs)

    async def _require_player(self, interaction: discord.Interaction) -> GuildPlayer | None:
        player = self._player(interaction)
        if player is None:
            await self._reply(interaction, t("not_in_voice", interaction.locale), ephemeral=True)
        return player

    # ---------- commands ----------

    @app_commands.command(name="play", description=_("Play a song from YouTube / YouTube Music (link or search)"))
    @app_commands.describe(query=_("Video link or search text"))
    async def play(self, interaction: discord.Interaction, query: str) -> None:
        loc = interaction.locale
        try:
            search = build_query(query)
        except QueryError as e:
            await interaction.response.send_message(f"⚠️ {t(e.key, loc)}", ephemeral=True)
            return

        player = self.players.get(interaction.guild_id)
        if player is not None and len(player.queue) >= config.MAX_QUEUE:
            await interaction.response.send_message(t("queue_full", loc, max=config.MAX_QUEUE), ephemeral=True)
            return

        await interaction.response.defer(thinking=True)
        vc = await self._connect(interaction)
        if vc is None:
            return

        try:
            info = await extract(search)
        except LookupError:
            await interaction.followup.send(t("no_results", loc))
            return
        except Exception as e:  # noqa: BLE001
            log.exception("Extraction failed for %r", query)
            await interaction.followup.send(t("not_found", loc, error=short_error(e)))
            return

        track = Track.from_info(info, requester=interaction.user.mention)
        player = self.players.get(interaction.guild_id)
        if player is not None and len(player.queue) >= config.MAX_QUEUE:
            await interaction.followup.send(t("queue_full", loc, max=config.MAX_QUEUE))
            return
        if player is None:
            player = GuildPlayer(self, interaction.guild, interaction.channel, loc)
            self.players[interaction.guild_id] = player
        player.locale = loc

        busy = player.current is not None or bool(player.queue)
        player.add(track)
        if busy:
            await interaction.followup.send(
                t("added", loc, pos=len(player.queue), link=track.link, duration=fmt_duration(track.duration, loc))
            )
        else:
            await interaction.followup.send(t("loading", loc, link=track.link))

    @app_commands.command(name="pause", description=_("Pause playback"))
    async def pause(self, interaction: discord.Interaction) -> None:
        vc = interaction.guild.voice_client
        if isinstance(vc, discord.VoiceClient) and vc.is_playing():
            vc.pause()
            await self._reply(interaction, t("paused", interaction.locale))
        else:
            await self._reply(interaction, t("nothing_playing", interaction.locale), ephemeral=True)

    @app_commands.command(name="resume", description=_("Resume playback"))
    async def resume(self, interaction: discord.Interaction) -> None:
        vc = interaction.guild.voice_client
        if isinstance(vc, discord.VoiceClient) and vc.is_paused():
            vc.resume()
            await self._reply(interaction, t("resumed", interaction.locale))
        else:
            await self._reply(interaction, t("not_paused", interaction.locale), ephemeral=True)

    @app_commands.command(name="skip", description=_("Skip to the next song"))
    async def skip(self, interaction: discord.Interaction) -> None:
        vc = interaction.guild.voice_client
        if isinstance(vc, discord.VoiceClient) and (vc.is_playing() or vc.is_paused()):
            vc.stop()  # triggers the after-callback -> next track
            await self._reply(interaction, t("skipped", interaction.locale))
        else:
            await self._reply(interaction, t("nothing_playing", interaction.locale), ephemeral=True)

    @app_commands.command(name="stop", description=_("Stop the music and clear the queue"))
    async def stop(self, interaction: discord.Interaction) -> None:
        player = await self._require_player(interaction)
        if player is None:
            return
        player.queue.clear()
        vc = interaction.guild.voice_client
        if isinstance(vc, discord.VoiceClient):
            vc.stop()
        await self._reply(interaction, t("stopped", interaction.locale))

    @app_commands.command(name="leave", description=_("Leave the voice channel"))
    async def leave(self, interaction: discord.Interaction) -> None:
        player = self._player(interaction)
        if player is not None:
            player.destroy()
        elif interaction.guild.voice_client:
            await interaction.guild.voice_client.disconnect(force=True)
        else:
            await self._reply(interaction, t("not_in_voice", interaction.locale), ephemeral=True)
            return
        await self._reply(interaction, t("bye", interaction.locale))

    @app_commands.command(name="queue", description=_("Show the queue"))
    async def queue(self, interaction: discord.Interaction) -> None:
        loc = interaction.locale
        player = await self._require_player(interaction)
        if player is None:
            return
        lines = []
        if player.current:
            lines.append(
                f"{t('queue_now', loc)} {player.current.link} `{fmt_duration(player.current.duration, loc)}`\n"
            )
        for i, track in enumerate(list(player.queue)[:15], start=1):
            lines.append(f"`{i}.` {track.link} `{fmt_duration(track.duration, loc)}`")
        if len(player.queue) > 15:
            lines.append(t("queue_more", loc, n=len(player.queue) - 15))
        if not lines:
            lines.append(t("queue_empty", loc))
        embed = discord.Embed(title=t("queue_title", loc), description="\n".join(lines), color=discord.Color.red())
        await self._reply(interaction, embed=embed)

    @app_commands.command(name="nowplaying", description=_("Show what's playing now"))
    async def nowplaying(self, interaction: discord.Interaction) -> None:
        player = await self._require_player(interaction)
        if player is None:
            return
        await self._reply(interaction, embed=self.now_playing_embed(player, interaction.locale))

    @app_commands.command(name="volume", description=_("Set the volume (0-100)"))
    @app_commands.describe(level=_("0 to 100"))
    async def volume(self, interaction: discord.Interaction, level: app_commands.Range[int, 0, 100]) -> None:
        player = await self._require_player(interaction)
        if player is None:
            return
        player.volume = level / 100
        vc = interaction.guild.voice_client
        if isinstance(vc, discord.VoiceClient) and isinstance(vc.source, discord.PCMVolumeTransformer):
            vc.source.volume = player.volume
        await self._reply(interaction, t("volume_set", interaction.locale, level=level))

    @app_commands.command(name="remove", description=_("Remove a song from the queue by number"))
    @app_commands.describe(position=_("Number from /queue"))
    async def remove(self, interaction: discord.Interaction, position: app_commands.Range[int, 1]) -> None:
        player = await self._require_player(interaction)
        if player is None:
            return
        if position > len(player.queue):
            await self._reply(interaction, t("no_such_position", interaction.locale), ephemeral=True)
            return
        track = player.queue[position - 1]
        del player.queue[position - 1]
        await self._reply(interaction, t("removed", interaction.locale, link=track.link))

    # ---------- events ----------

    @commands.Cog.listener()
    async def on_voice_state_update(
        self, member: discord.Member, before: discord.VoiceState, after: discord.VoiceState
    ) -> None:
        player = self.players.get(member.guild.id)
        if player is None:
            return

        # The bot itself was disconnected (kicked / moved out)
        if self.bot.user and member.id == self.bot.user.id and after.channel is None:
            player.destroy()
            return

        # Leave if everyone else left the channel
        vc = member.guild.voice_client
        if vc and before.channel == vc.channel and after.channel != vc.channel:
            if not any(not m.bot for m in vc.channel.members):
                await player.say(t("everyone_left", player.locale))
                player.destroy()


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Music(bot))
