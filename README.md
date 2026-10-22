# Enshrouded on AWS: start from Discord, stops itself when empty

Built with [Claude](https://www.anthropic.com/claude) (Anthropic): the infrastructure, Lambdas, scripts and docs were written by Claude working with a human who ran every deployment step and reviewed each plan.

```
Discord /enshrouded start ─► Lambda (Function URL) ─► ec2:StartInstances
                                                          │
 EC2 (m6i.xlarge, Ubuntu) ── docker: Enshrouded (Wine/Proton) ── EBS data volume
        │                                                          ▲
        ├─ idle_watcher.py: 0 players for 30 min ─► poweroff       │ snapshot on every stop
        │   also posts up / joined / left / shutting down           │ (EventBridge ─► Lambda)
        └─ Discord webhook ◄────────────────────────────────────────┘
```

Typical cost at ~20 h/week of play: about $25-30/month (compute only while running, plus EBS, snapshots and the Elastic IP).

## What's in here

| Path | Purpose |
|---|---|
| `terraform/` | All AWS resources. Works with Terraform or OpenTofu. |
| `lambda/index.mjs` | Discord handler: verifies signatures, checks guild/channel/role, starts/stops/describes one instance. No dependencies. |
| `lambda/snapshot.mjs` | Snapshots the data volume whenever the instance stops, and prunes old ones. |
| `discord/register_commands.mjs` | One-off script that registers `/enshrouded`. |
| `instance/` | Pushed to S3 by `terraform apply` and pulled by the server at every boot: compose file, idle watcher, systemd units, mods overlay. |
| `bootstrap/` | IAM policies for a restricted deploy role and its permissions boundary. |
| `tools/a2s_probe.py` | Asks a running server what it reports over the Steam query protocol. |
| `RESTORE.md` | How to restore a world from a snapshot, including a non-destructive practice restore. |
| `.claude/settings.json` | Claude Code may `fmt/validate/plan`; `apply`, `destroy`, `state`, IAM and SSM writes are denied. |

## Requirements and notes

- **Requirements:** an AWS account you control, Terraform 1.6+ (or OpenTofu), AWS CLI v2, Node 18+, a Discord server you manage, and the Session Manager plugin for the AWS CLI. The commands in the docs are macOS/zsh; adapt them for other shells.
- **Unofficial.** Not affiliated with or endorsed by Keen Games. The server runs the Windows dedicated server under Wine/Proton using a community Docker image (`mornedhels/enshrouded-server`). The compose file uses the `latest` tag; pin a version once you have a known-good one.
- **Cost.** You pay AWS for what this creates (roughly $25-30/month at ~20 h/week of play; prices change, so check the AWS Pricing Calculator). A budget alert is included but is only an email. The software is provided as is (see `LICENSE`).
- **Keep `name_prefix = "enshrouded"`** unless you also change the resource names in `bootstrap/*.json`; the deploy-role policy is scoped to that prefix.
- **Security notes.** The Lambda Function URL is public by design (Discord must reach it) and rejects anything without a valid Discord signature. The game port is open to the internet unless you narrow `allowed_cidrs`. There is no SSH; use SSM Session Manager. Secrets live in SSM Parameter Store, never in Terraform state or the repo. Terraform state is local by default; see the note in the Deploy section.

## One-time setup

New to AWS, or deploying with an AI agent? Follow [`docs/GUIDED_SETUP.md`](docs/GUIDED_SETUP.md): a step-by-step runbook (with the snags we hit) and interaction rules for agents. The summary below is the short version.

### 1. AWS accounts and sign-in
Use a dedicated AWS account for the server, so the blast radius is small. Short-lived credentials come from IAM Identity Center; do not create IAM access keys.

1. **Management account.** Enable AWS Organizations and IAM Identity Center. It must be an *organization* instance: an *account* instance cannot grant CLI access to AWS accounts. Choose single-region.
2. **Member account** for the server (Organizations ▸ Add an AWS account). Every AWS account needs its own unique root email. A plus-address works: `realmailbox+tag@yourdomain` (your real mailbox before the `+`, a tag after it). Updating that email later is possible from the management account (`aws account start-primary-email-update`, which needs trusted access for `account.amazonaws.com`).
3. **Permission sets** (Identity Center), both assigned to your user on the member account:
   - `AdminBootstrap`: `AdministratorAccess`. Only for one-time setup, writing secrets, shell sessions and restores.
   - `EnshroudedDeployer`: a *customer managed policy* named `enshrouded-deployer`. That policy must already exist in the member account before you create the permission set (next step).
4. **Create the two policies** in the member account while signed in as `AdminBootstrap` (CloudShell works; upload the two JSON files from `bootstrap/`):
   ```bash
   ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text); REGION=us-east-1   # the region you deploy to; must match 'region' in terraform.tfvars
   sed "s/ACCOUNT_ID/$ACCOUNT_ID/g; s/REGION/$REGION/g" boundary-policy.json > b.json
   sed "s/ACCOUNT_ID/$ACCOUNT_ID/g; s/REGION/$REGION/g" deployer-policy.json > d.json
   aws iam create-policy --policy-name enshrouded-boundary --policy-document file://b.json
   aws iam create-policy --policy-name enshrouded-deployer --policy-document file://d.json
   ```
5. **CLI profiles:** run `aws configure sso` twice (profile names `enshrouded-admin` and `enshrouded-deploy`), then `aws sso login --profile <name>` when a session expires.

Set `permissions_boundary_arn` in `terraform.tfvars`. The deployer policy only allows creating roles that carry that boundary, and cannot change or remove it. If you later change `bootstrap/deployer-policy.json`, publish it with `aws iam create-policy-version --policy-arn <arn> --policy-document file://<rendered file> --set-as-default` using the admin profile (the deployer cannot edit its own policy). If a plan or apply hits `AccessDenied`, widen the policy deliberately rather than switching to admin.

### 2. Discord
1. Developer Portal ▸ New Application. Copy the **Application ID** and **Public Key** (neither is secret).
2. Install it to your server with only the `applications.commands` scope (OAuth2 ▸ URL Generator).
3. Make a channel ▸ Integrations ▸ Webhooks ▸ New Webhook. Copy the webhook URL (a secret).
4. Enable Developer Mode in Discord to copy the server, channel and admin-role IDs.

### 3. Secrets (your own shell; never in chat or the repo)
The deploy role cannot write these on purpose, so use the admin profile. This prompt syntax is zsh; in bash use `read -s -p "Admin password: " P`. Use letters and numbers only for passwords (at least 12 characters), because special characters can break the generated config.
```zsh
read -s "P?Admin password: ";   echo; aws ssm put-parameter --profile enshrouded-admin --type SecureString --name /enshrouded/admin_password   --value "$P"; unset P
read -s "P?Friends password: "; echo; aws ssm put-parameter --profile enshrouded-admin --type SecureString --name /enshrouded/friends_password --value "$P"; unset P
read -s "P?Webhook URL: ";      echo; aws ssm put-parameter --profile enshrouded-admin --type SecureString --name /enshrouded/discord_webhook_url --value "$P"; unset P
```

### 4. Deploy
```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars   # fill in; git-ignored
cd terraform
AWS_PROFILE=enshrouded-deploy terraform init
AWS_PROFILE=enshrouded-deploy terraform validate
AWS_PROFILE=enshrouded-deploy terraform plan
AWS_PROFILE=enshrouded-deploy terraform apply      # you run this, after reading the plan
```
Paste the `discord_interactions_url` output into the Developer Portal ▸ General Information ▸ *Interactions Endpoint URL* (Discord sends a signed PING and the Lambda answers it). Then register the command, pasting the bot token at the prompt:

```zsh
read -s "T?Bot token: "; echo; DISCORD_APP_ID=... DISCORD_GUILD_ID=... DISCORD_BOT_TOKEN="$T" node discord/register_commands.mjs; unset T
```
The first boot installs Docker and downloads the game; allow 10-15 minutes. The idle watcher only counts a *successful* zero-player query, so a long first boot will not shut itself down.

**State:** Terraform state is local by default (git-ignored, contains no secrets). Losing it means Terraform loses track of what it built, so either back it up or move it to an S3 backend (see the comment in `terraform/versions.tf`).

## Using it
`/enshrouded start | status | stop` in the designated channel. Anyone who can use the command can start it; admin roles can also stop. The idle watcher also reads the game log and posts `<name> joined` / `<name> left` to the channel (names are sanitized and never ping anyone). Connect to the address the bot shows, using the password for your role: the admin password gives the Admins group, the friends password gives Friends.

## Changing config or mods
Edit files under `instance/` (or `terraform/templates/*.tftpl` for settings), run `terraform apply`, and the next start picks them up. Server config is env-driven (`SERVER_*` in `server.env.tftpl`; see the image docs).

**Mods are undecided.** Enshrouded has no official mod support. Community routes exist (a `.kfc` patcher; the EML Lua loader via a proxy `dbghelp.dll`) but neither is verified on a Wine/Proton dedicated server. `instance/mods/overlay/` is a placeholder: files there are copied over the server directory at boot. Patch-style mods can be overwritten by game updates, so a post-update step will be needed.

## Observed behavior (verified on a live deployment)
- The Steam A2S query reports a correct **player count**, which the idle shutdown depends on. It does not return player *names*; the game log does.
- Only UDP 15637 needs to be reachable for players to connect.
- Saves live in `/mnt/data/game/server/savegame` on the data volume.
- A start from stopped to "up" takes a few minutes.
- A snapshot is taken on every stop (idle, `/enshrouded stop`, or the uptime cap), and a restore from one was tested end to end.

## Operations
- Shell: SSM Session Manager (`aws ssm start-session --target <instance-id> --profile enshrouded-admin`; needs the Session Manager plugin). There is no SSH.
- Logs: `docker logs enshrouded`, `journalctl -u enshrouded-idle`, `/var/log/enshrouded-bootstrap.log`.
- Backups: a snapshot of the data volume is taken every time the instance stops, kept 14 days with at least the newest 3 retained. A daily DLM snapshot (7 retained) is a second layer. The volume has `prevent_destroy`. Restore steps are in `RESTORE.md`.
- Guardrails: hard uptime cap (default 12 h) in the watcher, an independent `shutdown` timer 30 min later, and an AWS Budget email at 80% actual / 100% forecast.
- Replacing the instance (new AMI, different size): `terraform apply -replace=aws_instance.server`. The world lives on the data volume. The Elastic IP is a separate resource, so the address stays the same.

## Working with AI agents in this repo
`AGENTS.md` (shared rules, imported by `CLAUDE.md`, which adds Claude Code specifics) and `.claude/settings.json` define what agents may do: edit files and run `fmt/validate/plan`; everything that changes AWS (`apply`, `destroy`, `state`, `import`, IAM, SSM writes, secrets) is denied or requires your approval. Read the plan, then run `terraform apply` yourself.
