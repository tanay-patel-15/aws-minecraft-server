#!/usr/bin/env bats

setup() {
  export STUB_DIR="$BATS_TEST_TMPDIR"
  PATH="$BATS_TEST_DIRNAME/stubs:$PATH"

  # A fake data disk with a world, and a fake console that records what is typed into it.
  export DATA_DIR="$BATS_TEST_TMPDIR/data"
  mkdir -p "$DATA_DIR/world"
  echo "level" > "$DATA_DIR/world/level.dat"
  echo "26.3" > "$DATA_DIR/version.txt"

  export CONSOLE="$STUB_DIR/events"
  export CONFIG_FILE="$BATS_TEST_TMPDIR/config.env"
  echo "BUCKET=test-bucket" > "$CONFIG_FILE"
  export SAVE_TIMEOUT=1

  BACKUP="$BATS_TEST_DIRNAME/../instance/mc-backup.sh"
}

# Loads restore_if_empty from the installer, pointed at the fake disk.
load_installer() {
  source "$BATS_TEST_DIRNAME/../instance/mc-install.sh"
  DATA_DIR="$BATS_TEST_TMPDIR/data"
  BUCKET=test-bucket
}

# Makes a real archive for the fake S3 to hand out, then empties the disk.
make_backup_in_s3() {
  tar -czf "$STUB_DIR/backup.tar.gz" -C "$DATA_DIR" world version.txt
  echo 1 > "$STUB_DIR/keycount"
  rm -rf "${DATA_DIR:?}"/*
  : > "$STUB_DIR/events"
}

@test "live backup sends save-off then save-all flush, and save-on after tar" {
  run "$BACKUP" --live
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_DIR/events")" = "$(printf 'save-off\nsave-all flush\ntar\nsave-on')" ]
  grep -q "s3 cp .* s3://test-bucket/backups/world.tar.gz" "$STUB_DIR/aws-calls"
}

@test "live backup sends save-on when tar fails, and uploads nothing" {
  touch "$STUB_DIR/tar-fails"
  run "$BACKUP" --live
  [ "$status" -ne 0 ]
  [ "$(tail -1 "$STUB_DIR/events")" = "save-on" ]
  ! grep -q "s3 cp" "$STUB_DIR/aws-calls"
}

@test "offline backup exits 0 when upload fails, so shutdown continues" {
  touch "$STUB_DIR/s3-fails"
  run "$BACKUP" --offline
  [ "$status" -eq 0 ]
  grep -q "s3 cp" "$STUB_DIR/aws-calls"
  [ ! -e "$STUB_DIR/events" ] || ! grep -q "save" "$STUB_DIR/events"
}

@test "offline backup uploads nothing when there is no world" {
  rm -rf "$DATA_DIR/world"
  run "$BACKUP" --offline
  [ "$status" -eq 0 ]
  [ ! -e "$STUB_DIR/aws-calls" ]
}

@test "restore_if_empty extracts the backup into an empty directory" {
  make_backup_in_s3
  load_installer
  run restore_if_empty
  [ "$status" -eq 0 ]
  [ "$(cat "$DATA_DIR/world/level.dat")" = "level" ]
  [ "$(cat "$DATA_DIR/version.txt")" = "26.3" ]
}

@test "restore_if_empty does nothing when a world exists" {
  load_installer
  run restore_if_empty
  [ "$status" -eq 0 ]
  [ ! -e "$STUB_DIR/aws-calls" ]
}

@test "restore_if_empty creates no world and exits non-zero when a backup exists but download fails" {
  make_backup_in_s3
  touch "$STUB_DIR/s3-fails"
  load_installer
  run restore_if_empty
  [ "$status" -ne 0 ]
  [ ! -e "$DATA_DIR/world" ]
}

@test "restore_if_empty exits 0 when there are no backups" {
  rm -rf "$DATA_DIR/world"
  load_installer
  run restore_if_empty
  [ "$status" -eq 0 ]
  [ ! -e "$DATA_DIR/world" ]
}

@test "restore_if_empty exits non-zero when it cannot check S3" {
  rm -rf "$DATA_DIR/world"
  touch "$STUB_DIR/s3-list-fails"
  load_installer
  run restore_if_empty
  [ "$status" -ne 0 ]
  [ ! -e "$DATA_DIR/world" ]
}