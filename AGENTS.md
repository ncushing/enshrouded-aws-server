# Enshrouded server on AWS

Infrastructure-as-code for an on-demand Enshrouded dedicated server:
Discord slash command -> Lambda -> EC2 start; an idle watcher on the instance stops it.

## Layout
- `terraform/`  all AWS resources (VPC, EC2, EBS, IAM, Lambdas, snapshots, budget)
- `lambda/`     Discord handler and post-shutdown snapshot function (Node, no dependencies)
- `discord/`    one-off slash-command registration script
- `instance/`   files synced to the instance from S3 at every boot (compose file, idle watcher, mods)
- `bootstrap/`  IAM policies an AWS admin applies once to create the restricted deploy role
- `tools/`      small helper scripts (e.g. query probe)
- `docs/GUIDED_SETUP.md`  step-by-step runbook and interaction rules for guiding a human through setup
- `RESTORE.md`  restoring a world from a snapshot

## Rules for agents
- You may run `fmt`, `validate`, `init`, `plan`. Never run `apply` or `destroy`; the human does that after reading the plan.
- Never read or print secrets. Secrets (Discord webhook URL, server passwords, bot token) live in SSM Parameter Store or the human's shell, never in the repo, tfvars, or chat.
- Keep IAM least-privilege. Any new permission needs a one-line justification.
- Do not add SSH access. Use SSM Session Manager.
- Do not put account IDs, IPs, Discord IDs, emails or names in tracked files. Personal values belong in the git-ignored `terraform/terraform.tfvars`.
- If you are helping a person deploy this, read `docs/GUIDED_SETUP.md` first and follow its interaction rules.
- Mod mechanism is undecided; see README "Changing config or mods".

Note: `.claude/settings.json` enforces the command restrictions above for Claude Code only. Other agents only have this text, so treat the rules as binding.
