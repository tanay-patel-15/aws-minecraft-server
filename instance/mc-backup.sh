#!/bin/bash
# Backs up the world to S3, in one of two modes:
#   --live     while Minecraft runs (from mc-backup.timer): pause saving, flush, archive, resume.
#   --offline  after Minecraft stops (ExecStopPost): archive the files as they are.
#              It never fails, so a problem here can't hold up a shutdown.
set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-/opt/mc/config.env}"
DATA_DIR="${DATA_DIR:-/srv/minecraft}"
CONSOLE="${CONSOLE:-/run/minecraft.stdin}"
SAVE_TIMEOUT="${SAVE_TIMEOUT:-60}"
BACKUP_KEY=backups/world.tar.gz

# Types a command into the Minecraft console.
console() {
  echo "$1" >> "$CONSOLE"
}

# Waits until Minecraft logs "Saved the game" at or after the time given.
wait_for_save() {
  local since=$1 i
  for ((i = 0; i < SAVE_TIMEOUT; i++)); do
    if journalctl -u minecraft --since "$since" -o cat | grep -q 'Saved the game'; then
      return 0
    fi
    sleep 1
  done
  echo "Minecraft did not confirm the save within ${SAVE_TIMEOUT}s" >&2
  return 1
}

# Writes the archive to $1: the world plus the files needed to bring it back as it was.
make_archive() {
  local out=$1 items=() f
  for f in world whitelist.json ops.json server.properties version.txt; do
    if [[ -e "$DATA_DIR/$f" ]]; then items+=("$f"); fi
  done
  tar -czf "$out" -C "$DATA_DIR" "${items[@]}"
}

upload() {
  aws s3 cp "$1" "s3://$BUCKET/$BACKUP_KEY" --only-show-errors
}

backup_live() {
  local since
  ARCHIVE=$(mktemp)
  # Whatever happens from here on, including a failure, saving gets switched back on.
  trap 'console "save-on"; rm -f "$ARCHIVE"' EXIT

  since=$(date '+%Y-%m-%d %H:%M:%S')
  console "save-off"
  console "save-all flush"
  wait_for_save "$since"
  make_archive "$ARCHIVE"

  # The archive is complete, so the world can change again while the upload runs.
  trap 'rm -f "$ARCHIVE"' EXIT
  console "save-on"
  upload "$ARCHIVE"
  echo "Backup uploaded to s3://$BUCKET/$BACKUP_KEY"
}

backup_offline() {
  # No world means nothing to save. Uploading anyway would replace a good backup.
  if [[ ! -d "$DATA_DIR/world" ]]; then
    echo "No world on disk; skipping the backup."
    return 0
  fi

  ARCHIVE=$(mktemp)
  trap 'rm -f "$ARCHIVE"' EXIT
  if make_archive "$ARCHIVE" && upload "$ARCHIVE"; then
    echo "Backup uploaded to s3://$BUCKET/$BACKUP_KEY"
  else
    echo "Backup failed; letting the shutdown continue." >&2
  fi
}

main() {
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"

  case "${1:-}" in
    --live) backup_live ;;
    --offline) backup_offline ;;
    *)
      echo "Usage: mc-backup.sh --live|--offline" >&2
      exit 2
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi