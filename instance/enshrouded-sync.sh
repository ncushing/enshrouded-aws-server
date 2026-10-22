#!/bin/bash
# Runs at every boot (ExecStartPre of enshrouded.service).
# Pulls the latest config from S3, installs systemd units, fetches secrets
# from SSM into a root-only env file, and applies the mods overlay.
set -euo pipefail

. /etc/enshrouded/boot.env
CTL=/opt/enshrouded-ctl
GAME=/mnt/data/game

aws s3 sync "s3://$BUCKET/instance/" "$CTL/" --region "$REGION" --delete --only-show-errors

# systemd units (changes take effect from the next boot)
cp "$CTL"/systemd/*.service /etc/systemd/system/
systemctl daemon-reload

# refresh this script too (atomic rename so the running copy is undisturbed)
cp "$CTL/enshrouded-sync.sh" /usr/local/bin/enshrouded-sync.sh.new
chmod 0755 /usr/local/bin/enshrouded-sync.sh.new
mv /usr/local/bin/enshrouded-sync.sh.new /usr/local/bin/enshrouded-sync.sh

# secrets -> root-only env file for docker compose (never written to S3 or git)
get() {
  aws ssm get-parameter --region "$REGION" --name "$PARAM_PREFIX/$1" \
    --with-decryption --query Parameter.Value --output text
}
umask 077
{
  echo "SERVER_ROLE_0_PASSWORD=$(get admin_password)"
  echo "SERVER_ROLE_1_PASSWORD=$(get friends_password)"
} > "$CTL/secrets.env"
umask 022

# mods overlay: files under instance/mods/overlay are copied over the server
# directory. Placeholder until a mod mechanism is chosen (see README).
if [ -d "$CTL/mods/overlay" ]; then
  mkdir -p "$GAME/server"
  rsync -a --exclude .gitkeep --exclude README.md "$CTL/mods/overlay/" "$GAME/server/"
  chown -R 4711:4711 "$GAME/server" || true
fi

# independent hard backstop: power off even if the idle watcher is dead
. "$CTL/idle.env"
shutdown -c 2>/dev/null || true
shutdown -P "+$(( MAX_UPTIME_HOURS * 60 + 30 ))" "enshrouded hard uptime backstop" || true
