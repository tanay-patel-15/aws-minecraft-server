#!/bin/bash
# Runs on every boot: fetches the latest scripts from S3, then prepares the server.
set -euo pipefail

BUCKET=$(cat /etc/mc-bucket)

aws s3 sync "s3://$BUCKET/scripts/" /opt/mc/
chmod +x /opt/mc/*.sh

cp /opt/mc/*.service /opt/mc/*.socket /etc/systemd/system/
for timer in /opt/mc/*.timer; do
  [[ -e "$timer" ]] || continue
  cp "$timer" /etc/systemd/system/
  systemctl enable "$(basename "$timer")"
done
systemctl daemon-reload

/opt/mc/mc-install.sh

systemctl enable minecraft.socket minecraft.service

# --no-block is needed: minecraft waits for this script, so waiting here would deadlock.
systemctl start --no-block minecraft.service