import logging
import sys

import discord
from discord import app_commands
from discord.ext import commands

import config
from i18n import BotTranslator, t

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

    async def on_app_command_error(
        self, interaction: discord.Interaction, error: app_commands.AppCommandError
    ) -> None:
        """Always answer a failed command, so it never stays on "<bot> is thinking..."."""
        if isinstance(error, app_commands.CheckFailure):
            return  # interaction_check already replied
        name = interaction.command.name if interaction.command else "?"
        log.error("Command /%s failed", name, exc_info=error)
        original = getattr(error, "original", error)
        detail = (str(original) or type(original).__name__).replace("`", "'")[:300]
        msg = t("command_error", interaction.locale, error=detail)
        try:
            if interaction.response.is_done():
                await interaction.followup.send(msg, ephemeral=True)
            else:
                await interaction.response.send_message(msg, ephemeral=True)
        except discord.HTTPException:
            pass

    async def setup_hook(self) -> None:
        self.tree.on_error = self.on_app_command_error
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


# start.ps1 restarts the bot after a crash, but not after this code: a bad .env won't fix itself.
CONFIG_ERROR_EXIT_CODE = 2


def config_error(en: str, bg: str) -> None:
    log.error(en)
    log.error(bg)
    sys.exit(CONFIG_ERROR_EXIT_CODE)


def main() -> None:
    discord.utils.setup_logging(level=logging.INFO)
    if not config.DISCORD_TOKEN:
        config_error(
            "DISCORD_TOKEN is missing. Copy .env.example to .env and fill it in.",
            "Липсва DISCORD_TOKEN. Копирай .env.example като .env и го попълни.",
        )

    bot = IxMusicBot()
    try:
        bot.run(config.DISCORD_TOKEN, log_handler=None)
    except discord.LoginFailure:
        config_error(
            "DISCORD_TOKEN is invalid. Copy a fresh token from Developer Portal -> Bot -> Reset Token.",
            "DISCORD_TOKEN е невалиден. Вземи нов токен от Developer Portal -> Bot -> Reset Token.",
        )
    except Exception:
        log.exception("The bot crashed")
        sys.exit(1)
    sys.exit(bot.exit_code)


if __name__ == "__main__":
    main()
