import logging
import sys

import discord
from discord.ext import commands

import config
from i18n import BotTranslator

log = logging.getLogger("ixmusic")

INVITE_PERMISSIONS = discord.Permissions(
    view_channel=True,
    send_messages=True,
    embed_links=True,
    connect=True,
    speak=True,
)


class IxMusicBot(commands.Bot):
    def __init__(self) -> None:
        intents = discord.Intents.default()  # includes voice_states
        super().__init__(
            command_prefix=commands.when_mentioned,
            intents=intents,
            # Never ping anyone (@everyone, roles, users), even if a video title contains a mention.
            allowed_mentions=discord.AllowedMentions.none(),
        )
        self.exit_code = 0

    async def setup_hook(self) -> None:
        await self.tree.set_translator(BotTranslator())
        await self.load_extension("cogs.music")
        if config.AUTO_UPDATE:
            await self.load_extension("cogs.updater")

        if config.GUILD_ID:
            guild = discord.Object(id=config.GUILD_ID)
            self.tree.copy_global_to(guild=guild)
            synced = await self.tree.sync(guild=guild)
            log.info("Synced %d commands to guild %s", len(synced), config.GUILD_ID)
        else:
            synced = await self.tree.sync()
            log.info("Synced %d global commands (may take up to an hour to appear)", len(synced))

    async def on_ready(self) -> None:
        assert self.user is not None
        log.info("Logged in as %s (ID: %s)", self.user, self.user.id)
        invite = discord.utils.oauth_url(
            self.user.id,
            permissions=INVITE_PERMISSIONS,
            scopes=("bot", "applications.commands"),
        )
        log.info("Invite link: %s", invite)
        if not self.guilds:
            log.warning("The bot is not in any server yet. Open the invite link above to add it.")
        await self.change_presence(
            activity=discord.Activity(type=discord.ActivityType.listening, name="/play")
        )


def main() -> None:
    if not config.DISCORD_TOKEN:
        print("DISCORD_TOKEN is missing. Copy .env.example to .env and fill it in.")
        print("Липсва DISCORD_TOKEN. Копирай .env.example като .env и го попълни.")
        sys.exit(1)

    discord.utils.setup_logging(level=logging.INFO)
    bot = IxMusicBot()
    bot.run(config.DISCORD_TOKEN, log_handler=None)
    sys.exit(bot.exit_code)


if __name__ == "__main__":
    main()
