"""Checks PyPI for new yt-dlp releases and restarts the bot (when idle) so run.bat installs them."""

from __future__ import annotations

import logging
import os

import aiohttp
import yt_dlp.version
from discord.ext import commands, tasks

import config

log = logging.getLogger("ixmusic.updater")

PYPI_URL = "https://pypi.org/pypi/yt-dlp/json"
RESTART_EXIT_CODE = 3  # run.bat loops on this code


def parse_version(v: str) -> tuple[int, ...]:
    return tuple(int(p) for p in v.split(".") if p.isdigit())


async def fetch_latest_version() -> str:
    timeout = aiohttp.ClientTimeout(total=15)
    async with aiohttp.ClientSession(timeout=timeout) as session:
        async with session.get(PYPI_URL) as resp:
            resp.raise_for_status()
            data = await resp.json()
    return data["info"]["version"]


class Updater(commands.Cog):
    def __init__(self, bot: commands.Bot):
        self.bot = bot
        self.pending_version: str | None = None
        self.check.change_interval(hours=config.UPDATE_CHECK_HOURS)
        self.check.start()

    async def cog_unload(self) -> None:
        self.check.cancel()
        self.restart_when_idle.cancel()

    @tasks.loop(hours=24)
    async def check(self) -> None:
        current = yt_dlp.version.__version__
        try:
            latest = await fetch_latest_version()
        except Exception as e:  # noqa: BLE001
            log.warning("Could not check for yt-dlp updates: %s", e)
            return

        if parse_version(latest) <= parse_version(current):
            log.info("yt-dlp is up to date (%s)", current)
            return

        log.info("New yt-dlp version available: %s (installed: %s)", latest, current)
        if not os.getenv("IXMUSIC_LAUNCHER"):
            log.warning("Start the bot with run.bat to install updates automatically.")
            return

        self.pending_version = latest
        self.check.stop()
        self.restart_when_idle.start()

    @check.before_loop
    async def _wait_ready(self) -> None:
        await self.bot.wait_until_ready()

    @tasks.loop(minutes=5)
    async def restart_when_idle(self) -> None:
        music = self.bot.get_cog("Music")
        if music is not None and getattr(music, "players", None):
            return  # music is playing somewhere; try again later
        log.info("Restarting to install yt-dlp %s", self.pending_version)
        self.bot.exit_code = RESTART_EXIT_CODE  # type: ignore[attr-defined]
        await self.bot.close()


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Updater(bot))
