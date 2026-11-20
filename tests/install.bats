#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../instance/mc-install.sh"
  MANIFEST="$BATS_TEST_TMPDIR/manifest.json"
  PIN_FILE="$BATS_TEST_TMPDIR/version.txt"
  echo '{"latest":{"release":"26.3"},"versions":[]}' > "$MANIFEST"
}

@test "resolve_version uses latest release when no pin exists" {
  run resolve_version "$PIN_FILE" "$MANIFEST"
  [ "$status" -eq 0 ]
  [ "$output" = "26.3" ]
}

@test "resolve_version keeps the pinned version when a newer release exists" {
  echo "26.1" > "$PIN_FILE"
  run resolve_version "$PIN_FILE" "$MANIFEST"
  [ "$status" -eq 0 ]
  [ "$output" = "26.1" ]
}

# Fake curl and rpm, so tests never touch the network or install anything.
# The fake curl records each call, then fails as if Mojang were down.
use_fake_commands() {
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  printf '#!/bin/bash\necho "curl $*" >> "%s/curl-calls"\nexit 1\n' "$BATS_TEST_TMPDIR" > "$bin/curl"
  printf '#!/bin/bash\nexit 0\n' > "$bin/rpm"
  chmod +x "$bin"/*
  PATH="$bin:$PATH"
}

# Sets up a data folder with a jar, a pin, and an installed.txt record.
make_install() {
  local pinned=$1 installed_sha=$2
  DATA_DIR="$BATS_TEST_TMPDIR/data"
  mkdir -p "$DATA_DIR"
  echo "fake jar" > "$DATA_DIR/server.jar"
  echo "$pinned" > "$DATA_DIR/version.txt"
  if [[ "$installed_sha" == "real" ]]; then
    installed_sha=$(file_sha1 "$DATA_DIR/server.jar")
  fi
  echo "26.3 25 $installed_sha" > "$DATA_DIR/installed.txt"
}

@test "install_server skips Mojang when the installed jar matches the pin" {
  use_fake_commands
  make_install 26.3 real
  run install_server
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/curl-calls" ]
}

@test "install_server contacts Mojang when the jar fails its checksum" {
  use_fake_commands
  make_install 26.3 0000000000000000000000000000000000000000
  run install_server
  [ -e "$BATS_TEST_TMPDIR/curl-calls" ]
}

@test "install_server contacts Mojang when the pin differs from the installed version" {
  use_fake_commands
  make_install 26.4 real
  run install_server
  [ -e "$BATS_TEST_TMPDIR/curl-calls" ]
}