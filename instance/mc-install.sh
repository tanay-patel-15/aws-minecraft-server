#!/bin/bash
# Prepares the data disk, Java, and Minecraft. Runs on every boot, so every
# step must be safe to repeat.
set -euo pipefail

CONFIG_FILE=/opt/mc/config.env
DATA_DIR=/srv/minecraft
MANIFEST_URL=https://piston-meta.mojang.com/mc/game/version_manifest_v2.json
BACKUP_KEY=backups/world.tar.gz

# Prints the version to install: the pinned one if it exists, otherwise latest.
resolve_version() {
  local pin_file=$1 manifest=$2
  if [[ -s "$pin_file" ]]; then
    cat "$pin_file"
  else
    jq -r '.latest.release' "$manifest"
  fi
}

mount_data_volume() {
  local device="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${VOLUME_ID//-/}"

  # The disk can attach a little after boot, so wait for it.
  for _ in {1..60}; do
    [[ -e "$device" ]] && break
    sleep 2
  done
  [[ -e "$device" ]] || { echo "Data volume $VOLUME_ID not found" >&2; return 1; }

  # Format only a blank disk. This line must never touch a disk that has data.
  if ! blkid "$device" > /dev/null; then
    mkfs.xfs -L mcdata "$device"
  fi

  mkdir -p "$DATA_DIR"
  grep -q 'LABEL=mcdata' /etc/fstab ||
    echo "LABEL=mcdata $DATA_DIR xfs defaults,nofail 0 2" >> /etc/fstab
  mountpoint -q "$DATA_DIR" || mount "$DATA_DIR"
}

# Restores the world from S3 when the data disk has none. It fails, and so stops
# Minecraft from starting, when a backup exists but can't be restored. Otherwise
# Minecraft would create a brand-new world, and its first backup would replace the real one.
restore_if_empty() {
  local count stage

  if [[ -d "$DATA_DIR/world" ]]; then
    return 0
  fi

  # A failed check is not the same as "no backups", so it stops the boot too.
  if ! count=$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "$BACKUP_KEY" \
      --query KeyCount --output text); then
    echo "Could not check S3 for a backup; not starting a new world." >&2
    return 1
  fi
  if [[ "$count" == 0 ]]; then
    echo "No backup in S3; Minecraft will create a new world."
    return 0
  fi

  # Unpack into a staging folder first, so a failure never leaves a half-restored world.
  stage="$DATA_DIR/.restore"
  rm -rf "$stage"
  mkdir -p "$stage"
  if ! aws s3 cp "s3://$BUCKET/$BACKUP_KEY" "$stage/world.tar.gz" --only-show-errors ||
    ! tar -xzf "$stage/world.tar.gz" -C "$stage" || [[ ! -d "$stage/world" ]]; then
    echo "A backup exists but could not be restored; not starting a new world." >&2
    rm -rf "$stage"
    return 1
  fi

  rm "$stage/world.tar.gz"
  mv "$stage"/* "$DATA_DIR"/
  rm -rf "$stage"
  echo "Restored the world from s3://$BUCKET/$BACKUP_KEY"
}

# Prints a file's SHA-1 fingerprint. Comparing text works on both Linux and macOS.
file_sha1() {
  sha1sum "$1" | cut -d ' ' -f 1
}

install_server() {
  local work manifest metadata version url major jar_url jar_sha java_pkg
  local pinned installed_version installed_major installed_sha

    # Fast path: if the jar on disk is the pinned version and still matches its saved fingerprint, skip Mojang entirely, so boots work even when Mojang is down.
    # saved fingerprint, skip Mojang entirely, so boots work even when Mojang is down.
  if [[ -s "$DATA_DIR/version.txt" && -s "$DATA_DIR/installed.txt" && -f "$DATA_DIR/server.jar" ]]; then
    pinned=$(cat "$DATA_DIR/version.txt")
    read -r installed_version installed_major installed_sha < "$DATA_DIR/installed.txt"
    if [[ "$pinned" == "$installed_version" && "$(file_sha1 "$DATA_DIR/server.jar")" == "$installed_sha" ]]; then
      java_pkg="java-${installed_major}-amazon-corretto-headless"
      rpm -q "$java_pkg" > /dev/null || dnf install -y "$java_pkg"
      return 0
    fi
  fi

  work=$(mktemp -d)
  manifest="$work/manifest.json"
  metadata="$work/version.json"

  curl -fsSL "$MANIFEST_URL" -o "$manifest"
  version=$(resolve_version "$DATA_DIR/version.txt" "$manifest")
  url=$(jq -r --arg v "$version" '.versions[] | select(.id == $v) | .url' "$manifest")
  curl -fsSL "$url" -o "$metadata"

  major=$(jq -r '.javaVersion.majorVersion' "$metadata")
  jar_url=$(jq -r '.downloads.server.url' "$metadata")
  jar_sha=$(jq -r '.downloads.server.sha1' "$metadata")

  java_pkg="java-${major}-amazon-corretto-headless"
  rpm -q "$java_pkg" > /dev/null || dnf install -y "$java_pkg"

  # The checksum answers both questions: is the jar missing, and is it the right version?
  if [[ ! -f "$DATA_DIR/server.jar" || "$(file_sha1 "$DATA_DIR/server.jar")" != "$jar_sha" ]]; then
    curl -fsSL "$jar_url" -o "$work/server.jar"
    if [[ "$(file_sha1 "$work/server.jar")" != "$jar_sha" ]]; then
      echo "Downloaded server.jar failed its checksum" >&2
      return 1
    fi
    mv "$work/server.jar" "$DATA_DIR/server.jar"
  fi

  echo "$version" > "$DATA_DIR/version.txt"
  echo "$version $major $jar_sha" > "$DATA_DIR/installed.txt"
  rm -rf "$work"
}

write_config() {
  echo "eula=true" > "$DATA_DIR/eula.txt"

  # Written once, so later edits to server.properties survive a reboot.
  if [[ ! -e "$DATA_DIR/server.properties" ]]; then
    cat > "$DATA_DIR/server.properties" << 'PROPERTIES'
white-list=true
enforce-whitelist=true
online-mode=true
PROPERTIES
  fi
}

main() {
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"

  if [[ "${EULA:-}" != "true" ]]; then
    echo "The Minecraft EULA has not been accepted" >&2
    exit 1
  fi

  rpm -q jq > /dev/null || dnf install -y jq
  id minecraft > /dev/null 2>&1 ||
    useradd --system --home-dir "$DATA_DIR" --shell /sbin/nologin minecraft

  mount_data_volume
  restore_if_empty
  install_server
  write_config
  chown -R minecraft:minecraft "$DATA_DIR"
}

# Run only when executed directly, so tests can load the functions above.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi