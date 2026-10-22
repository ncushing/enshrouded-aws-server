@AGENTS.md

## Claude Code specifics

- The command rules in `AGENTS.md` are enforced for you by `.claude/settings.json`: `terraform apply/destroy/state/import`, `aws iam`, SSM writes and reading secrets or tfvars are denied; other `aws` and `curl` commands ask first. Do not route around a denied action with scripts or other tools. If one is needed, give the human the exact command to run themselves.
- For infrastructure changes that touch several files (Terraform plus IAM policy plus docs), use plan mode first and keep `bootstrap/deployer-policy.json` in step with any new AWS permission the Terraform needs.
- When guiding someone through setup, follow the interaction rules in `docs/GUIDED_SETUP.md`: a few steps at a time, continuous numbering, exact syntax, secrets only typed into the terminal.
- Personal notes or local overrides go in `CLAUDE.local.md`, which is git-ignored.
