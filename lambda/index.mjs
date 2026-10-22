// Discord slash-command handler for the Enshrouded server.
// Function URL -> verify Ed25519 signature -> check guild/channel/role -> EC2 start/stop/status.
// No dependencies: Node 22 ships crypto with Ed25519 and the Lambda runtime bundles the AWS SDK v3.
import { createPublicKey, verify } from "node:crypto";
import {
  EC2Client,
  DescribeInstancesCommand,
  StartInstancesCommand,
  StopInstancesCommand,
} from "@aws-sdk/client-ec2";

const ec2 = new EC2Client({});

const csv = (v) => new Set((v ?? "").split(",").map((s) => s.trim()).filter(Boolean));
const cfg = () => ({
  instanceId: process.env.INSTANCE_ID,
  publicKey: process.env.DISCORD_PUBLIC_KEY,
  guildId: process.env.ALLOWED_GUILD_ID,
  channelId: process.env.ALLOWED_CHANNEL_ID,
  playerRoles: csv(process.env.PLAYER_ROLE_IDS),
  adminRoles: csv(process.env.ADMIN_ROLE_IDS),
  address: process.env.SERVER_ADDRESS,
  port: process.env.SERVER_PORT,
  idleMinutes: process.env.IDLE_MINUTES,
});

// DER prefix that wraps a raw 32-byte Ed25519 public key as SPKI.
const SPKI_PREFIX = Buffer.from("302a300506032b6570032100", "hex");

function signatureValid(headers, rawBody, publicKeyHex) {
  const sig = headers["x-signature-ed25519"];
  const ts = headers["x-signature-timestamp"];
  if (!sig || !ts || !publicKeyHex) return false;
  const age = Math.abs(Date.now() / 1000 - Number(ts));
  if (!Number.isFinite(age) || age > 300) return false; // replay protection
  try {
    const key = createPublicKey({
      key: Buffer.concat([SPKI_PREFIX, Buffer.from(publicKeyHex, "hex")]),
      format: "der",
      type: "spki",
    });
    return verify(null, Buffer.from(ts + rawBody), key, Buffer.from(sig, "hex"));
  } catch {
    return false;
  }
}

const json = (statusCode, body) => ({
  statusCode,
  headers: { "content-type": "application/json" },
  body: JSON.stringify(body),
});

const reply = (content, ephemeral = false) =>
  json(200, {
    type: 4,
    data: {
      content,
      allowed_mentions: { parse: [] },
      ...(ephemeral ? { flags: 64 } : {}),
    },
  });

async function describe(instanceId) {
  const r = await ec2.send(new DescribeInstancesCommand({ InstanceIds: [instanceId] }));
  return r.Reservations?.[0]?.Instances?.[0];
}

async function handleCommand(interaction, c) {
  const sub = interaction.data?.options?.[0]?.name;
  const roles = interaction.member?.roles ?? [];
  const isAdmin = roles.some((r) => c.adminRoles.has(r));
  const isPlayer = isAdmin || c.playerRoles.size === 0 || roles.some((r) => c.playerRoles.has(r));
  const user = interaction.member?.user?.id ?? "unknown";

  if (!isPlayer) return reply("You don't have a role that can control the server.", true);

  const inst = await describe(c.instanceId);
  const state = inst?.State?.Name ?? "unknown";
  const addr = `\`${c.address}:${c.port}\``;
  console.log(JSON.stringify({ action: sub, user, state }));

  if (sub === "status") {
    if (state === "running") return reply(`🟢 Instance is running. Connect to ${addr}. (Players are checked by the server itself; it stops after ${c.idleMinutes} min empty.)`);
    if (state === "pending") return reply("🟡 Instance is starting. You'll get a message here when the game is ready.");
    if (state === "stopping" || state === "shutting-down") return reply("🟠 Instance is shutting down.");
    return reply(`⚫ Server is ${state}. Use \`/enshrouded start\` to boot it.`);
  }

  if (sub === "start") {
    if (state === "running") return reply(`🟢 Already running. Connect to ${addr}. If you just started it, give the game a few minutes to load.`);
    if (state === "pending") return reply("🟡 Already starting. You'll get a message here when it's ready.");
    if (state === "stopping" || state === "shutting-down") return reply("🟠 It's still shutting down. Try again in a minute.");
    if (state !== "stopped") return reply(`Unexpected instance state: ${state}.`, true);
    await ec2.send(new StartInstancesCommand({ InstanceIds: [c.instanceId] }));
    return reply(`🟡 Starting the server (<@${user}> asked). Boot plus world load takes a few minutes; I'll post here when it's ready.`);
  }

  if (sub === "stop") {
    if (!isAdmin) return reply("Only admins can stop the server. It also stops itself after being empty.", true);
    if (state === "stopped") return reply("Already stopped.");
    if (state === "stopping" || state === "shutting-down") return reply("Already shutting down.");
    await ec2.send(new StopInstancesCommand({ InstanceIds: [c.instanceId] }));
    return reply(`🔴 Stopping the server (<@${user}> asked). The world is saved on shutdown.`);
  }

  return reply("Unknown subcommand.", true);
}

export async function handler(event) {
  const c = cfg();
  const headers = Object.fromEntries(
    Object.entries(event.headers ?? {}).map(([k, v]) => [k.toLowerCase(), v]),
  );
  const rawBody = event.isBase64Encoded
    ? Buffer.from(event.body ?? "", "base64").toString("utf8")
    : (event.body ?? "");

  if (!signatureValid(headers, rawBody, c.publicKey)) {
    return { statusCode: 401, body: "invalid request signature" };
  }

  let interaction;
  try {
    interaction = JSON.parse(rawBody);
  } catch {
    return { statusCode: 400, body: "bad json" };
  }

  if (interaction.type === 1) return json(200, { type: 1 }); // PING

  if (interaction.type !== 2) return reply("Unsupported interaction.", true);

  if (interaction.guild_id !== c.guildId || interaction.channel_id !== c.channelId) {
    return reply("This command only works in the server's designated channel.", true);
  }

  try {
    return await handleCommand(interaction, c);
  } catch (err) {
    console.error("command failed", err);
    return reply("Something went wrong talking to AWS. Check the Lambda logs.", true);
  }
}
