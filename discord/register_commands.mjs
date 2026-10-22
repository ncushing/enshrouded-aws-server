// One-off: registers the /enshrouded slash command in your guild.
// Usage (token stays in your shell, never in the repo):
//   DISCORD_APP_ID=... DISCORD_GUILD_ID=... DISCORD_BOT_TOKEN=... node discord/register_commands.mjs
const { DISCORD_APP_ID, DISCORD_GUILD_ID, DISCORD_BOT_TOKEN } = process.env;
if (!DISCORD_APP_ID || !DISCORD_GUILD_ID || !DISCORD_BOT_TOKEN) {
  console.error("Set DISCORD_APP_ID, DISCORD_GUILD_ID and DISCORD_BOT_TOKEN.");
  process.exit(1);
}

const commands = [
  {
    name: "enshrouded",
    description: "Control the Enshrouded server",
    options: [
      { type: 1, name: "start", description: "Start the server" },
      { type: 1, name: "status", description: "Is the server running, and where do I connect?" },
      { type: 1, name: "stop", description: "Stop the server (admins only)" },
    ],
  },
];

const res = await fetch(
  `https://discord.com/api/v10/applications/${DISCORD_APP_ID}/guilds/${DISCORD_GUILD_ID}/commands`,
  {
    method: "PUT",
    headers: { "content-type": "application/json", authorization: `Bot ${DISCORD_BOT_TOKEN}` },
    body: JSON.stringify(commands),
  },
);
console.log(res.status, await res.text());
process.exit(res.ok ? 0 : 1);
