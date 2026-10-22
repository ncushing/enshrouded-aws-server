# Guided setup: a human and an AI agent deploying this together

This is a runbook for an agent to walk a person through the whole deployment, and
for a person to follow alone. It was written after doing exactly that, including
the mistakes. The commands are macOS/zsh; adapt as needed.

## Rules for the agent (read these first)

The person is a human reading on a screen, scrolling to find their place, and
every answer they give can change the next steps.

1. **One to three steps per message, then stop and wait for the result.** Never dump ten steps. Their output decides what comes next.
2. **Number steps continuously for the whole session.** Do not restart at 1 under each heading.
3. **Say exactly what to type.** For every value, say whether it is literal (type it as shown) or a placeholder (replace it, and leave out the `<` `>`), and what format it must have. Example: a plus-address is `realmailbox+tag@domain`, with the real mailbox before the `+`.
4. **Say what success looks like** ("prints `"Version": 1`") and **what to paste back**.
5. **Prefer commands over console clicking.** AWS console menus change and there are thousands of pages. Use CloudShell (the `>_` icon in the console's top bar) with paste-able commands. When clicking is unavoidable, give the click path and a fallback ("search for X in the top search bar").
6. **Ask about their machine when it matters** (Homebrew or not, zsh or bash, OS) instead of guessing.
7. **Secrets never go in chat.** Use `read -s` prompts so values are typed into the terminal only. If someone pastes one anyway, say plainly that it is exposed, what the risk is, and let them decide whether to rotate it.
8. **Never run `terraform apply`, and do not run IAM or SSM writes for them.** Show the plan, they read it, they apply.
9. **Verify AWS and tool details against current docs** when unsure, and say when something is unverified. Do not invent menu names.
10. **Tidy up** temporary resources (test volumes, extra webhooks) and say so.

## Runbook

### Tools (on the person's computer)
1. Install AWS CLI v2: `brew install awscli`, or the official `.pkg` from the AWS CLI install page. Check with `aws --version`.
2. Install Terraform: `brew tap hashicorp/tap` then `brew install hashicorp/tap/terraform`. Plain `brew install terraform` installs an old version that is too old for this project. Check with `terraform version`.
3. Install Node 18+ (the Discord registration script uses built-in `fetch`) and the Session Manager plugin: `brew install --cask session-manager-plugin`.

### AWS accounts
4. Management account: sign up at aws.amazon.com, add payment, enable MFA on the root user, then stop using root.
5. Create the organization (console: AWS Organizations). Confirm the verification email.
6. Optional, only if a member account's root email ever needs changing: in CloudShell run `aws organizations enable-aws-service-access --service-principal account.amazonaws.com` (the principal is literal).
7. Create the member account (Organizations ▸ AWS accounts ▸ Add an AWS account). Name it `enshrouded`. Root email must be unique; use a plus-address `realmailbox+tag@yourdomain` (real mailbox before the `+`). Test that mail to it actually arrives first.
8. Optional: set the member account's root password via "Forgot password", and enable MFA. Day to day you never use root.

### Sign-in (IAM Identity Center, in the management account)
9. Enable IAM Identity Center (the organization instance, single-region). Pick a region near your players; it cannot be moved later. A name prompt for the instance is only a label.
10. Users ▸ Add user: your name and a real inbox. Accept the invitation and register MFA. Note the AWS access portal URL (`https://d-xxxxxxxxxx.awsapps.com/start`).
11. Permission sets ▸ Create: predefined `AdministratorAccess`, named `AdminBootstrap`, 8-hour session.
12. AWS accounts ▸ tick the `enshrouded` account ▸ Assign users or groups ▸ you ▸ `AdminBootstrap`.
13. Sign in to the portal, open the `enshrouded` account as `AdminBootstrap`, open CloudShell, and upload `bootstrap/boundary-policy.json` and `bootstrap/deployer-policy.json` (Actions ▸ Upload file).
14. In CloudShell, create both policies (nothing to replace: it looks up the account ID; change `REGION` to yours):
    ```
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text); REGION=us-east-1   # the region you deploy to; must match 'region' in terraform.tfvars
    sed "s/ACCOUNT_ID/$ACCOUNT_ID/g; s/REGION/$REGION/g" boundary-policy.json > b.json
    sed "s/ACCOUNT_ID/$ACCOUNT_ID/g; s/REGION/$REGION/g" deployer-policy.json > d.json
    aws iam create-policy --policy-name enshrouded-boundary --policy-document file://b.json
    aws iam create-policy --policy-name enshrouded-deployer --policy-document file://d.json
    ```
    Keep the boundary ARN it prints; it goes in `terraform.tfvars`.
15. Back in the management account: Permission sets ▸ Create ▸ Custom ▸ Customer managed policies ▸ attach `enshrouded-deployer` (exact name, no path). Name it `EnshroudedDeployer`, 8-hour session, then assign it to yourself on the `enshrouded` account. The policy must already exist in that account (step 14) or this fails.
16. On the computer: `aws configure sso`. Session name `home-sso`, start URL is the portal URL **without** a trailing `/#/`, SSO region is where Identity Center lives. Choose `AdminBootstrap`, profile name `enshrouded-admin`. Run it again for `EnshroudedDeployer` as `enshrouded-deploy`.
17. Check both: `aws sts get-caller-identity --profile enshrouded-admin` (role name contains `AdminBootstrap`) and `--profile enshrouded-deploy`. When a session expires: `aws sso login --profile <name>`.

### Secrets (admin profile; the deploy role cannot write these on purpose)
18. Admin password (the prompt shows nothing as you type; letters and numbers only, 12+ characters):
    ```
    read -s "P?Admin password: "; echo; aws ssm put-parameter --profile enshrouded-admin --type SecureString --name /enshrouded/admin_password --value "$P"; unset P
    ```
    Success prints `"Version": 1`. In bash use `read -s -p "Admin password: " P`.
19. Same for `/enshrouded/friends_password` (the password friends type to join).

### Discord
20. Developer Portal ▸ New Application. Copy the Application ID and Public Key (neither is secret).
21. OAuth2 ▸ URL Generator: tick only the `applications.commands` scope, open the generated URL, pick your server, Authorize.
22. In Discord: User Settings ▸ Advanced ▸ Developer Mode on. Right-click your server ▸ Copy Server ID. Create a text channel, right-click it ▸ Copy Channel ID. Server Settings ▸ Roles ▸ create an admin role, give it to yourself, right-click it ▸ Copy Role ID.
23. Channel gear icon ▸ Integrations ▸ Webhooks ▸ New Webhook ▸ Copy Webhook URL. **Do not paste it in chat.** Store it:
    ```
    read -s "P?Webhook URL: "; echo; aws ssm put-parameter --profile enshrouded-admin --type SecureString --name /enshrouded/discord_webhook_url --value "$P"; unset P
    ```

### Deploy
24. `cp terraform/terraform.tfvars.example terraform/terraform.tfvars` and fill it in (region, budget email, server name, the Discord IDs and public key, `permissions_boundary_arn`). The file is git-ignored.
25. `cd terraform`, then `AWS_PROFILE=enshrouded-deploy terraform init`.
26. `AWS_PROFILE=enshrouded-deploy terraform validate` should say `Success!`.
27. `AWS_PROFILE=enshrouded-deploy terraform plan`. The first run adds roughly 40 resources and changes or destroys none. Read it.
28. `AWS_PROFILE=enshrouded-deploy terraform apply`, then `yes`. If it fails reading an S3 object ("couldn't find resource"), run it again; the state was saved.
29. Paste the `discord_interactions_url` output into the Developer Portal ▸ General Information ▸ Interactions Endpoint URL and save. Success means the Lambda answered Discord's signed check. A "server is up" message appears in the channel when the game is ready.
30. Register the command (the token comes from Bot ▸ Reset Token or Copy; never paste it in chat):
    ```
    read -s "T?Bot token: "; echo; DISCORD_APP_ID=<id> DISCORD_GUILD_ID=<server-id> DISCORD_BOT_TOKEN="$T" node discord/register_commands.mjs; unset T
    ```
    It prints `200` on success.
31. In the channel run `/enshrouded status`. It should report the instance state and address.

### Verify
32. Join the game (direct connect to the address shown) with the friends password.
33. Confirm the idle watcher sees players: `aws ssm start-session --target <instance-id> --profile enshrouded-admin`, then `sudo journalctl -u enshrouded-idle -n 15 --no-pager`. Look for `players=` with a number that changes when you join.
34. Leave and wait about 30 minutes. The channel should post a shutdown message and `/enshrouded status` should show stopped. Then list snapshots (command in `RESTORE.md`): one starting `Post-shutdown` should exist.
35. Do the practice restore in `RESTORE.md`, one step at a time, and clean up the temporary volume.

## Snags we hit, and the fixes
| Symptom | Cause | Fix |
|---|---|---|
| Password-reset email never arrives for a new account | Plus-address written backwards (`tag+realmailbox@`) so the mailbox does not exist | Mailbox first: `realmailbox+tag@domain`; change the account email from the management account (see step 6) |
| `aws: command not found` | CLI not installed or old terminal window | Install (step 1), open a new terminal |
| Permission set creation cannot find the policy | Policy not in that account yet, or name/path differs | Create it in the member account first (step 14); exact name, no path |
| `terraform apply` fails with S3 "couldn't find resource" | Timing after creating the bucket | Run `apply` again |
| Joining works but idle shutdown never fires | Query not returning a player count | Check step 33; the watcher only counts successful zero-player queries |
| Idle watcher shuts down right after a restart | Stale idle timer from before an outage | Fixed in `idle_watcher.py` (idle time resets whenever a query fails) |
| `AccessDenied` on plan/apply | Deployer policy missing an action | Add it to `bootstrap/deployer-policy.json` deliberately and publish with `aws iam create-policy-version ... --set-as-default` using the admin profile |
