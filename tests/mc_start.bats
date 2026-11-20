#!/usr/bin/env bats

setup() {
  export STUB_DIR="$BATS_TEST_TMPDIR"
  PATH="$BATS_TEST_DIRNAME/stubs:$PATH"

  # Preset the Terraform outputs, so tests never run terraform.
  export INSTANCE_ID=i-test SG_ID=sg-test PUBLIC_IP=198.51.100.10
  export MC_POLL_SECONDS=0

  BIN="$BATS_TEST_DIRNAME/../bin"
  source "$BIN/lib.sh"
}

# Prints the line number of the first logged AWS call that matches $1.
call_line() {
  grep -n -- "$1" "$STUB_DIR/aws-calls" | head -1 | cut -d: -f1
}

@test "sync_ingress replaces an old IP rule with the current IP" {
  echo "198.51.100.99/32" > "$STUB_DIR/cidrs"
  run sync_ingress 203.0.113.7
  [ "$status" -eq 0 ]
  grep -q "revoke-security-group-ingress .*198.51.100.99/32" "$STUB_DIR/aws-calls"
  grep -q "authorize-security-group-ingress .*203.0.113.7/32" "$STUB_DIR/aws-calls"
}

@test "sync_ingress makes no change when the rule already matches" {
  echo "203.0.113.7/32" > "$STUB_DIR/cidrs"
  run sync_ingress 203.0.113.7
  [ "$status" -eq 0 ]
  ! grep -qE "revoke|authorize" "$STUB_DIR/aws-calls"
}

@test "mc-start waits when the instance is stopping, then starts it" {
  echo stopping > "$STUB_DIR/state"
  run "$BIN/mc-start"
  [ "$status" -eq 0 ]
  [ "$(call_line 'wait instance-stopped')" -lt "$(call_line 'start-instances')" ]
  [[ "$output" == *"Server ready: 198.51.100.10"* ]]
}

@test "mc-start does not call start-instances when already running" {
  echo running > "$STUB_DIR/state"
  run "$BIN/mc-start"
  [ "$status" -eq 0 ]
  ! grep -q "start-instances" "$STUB_DIR/aws-calls"
}

@test "require_aws_cli fails clearly when aws is not aws-cli/2" {
  STUB_AWS_VERSION="aws-cli/1.29.0 Python/3.9" run require_aws_cli
  [ "$status" -eq 1 ]
  [[ "$output" == *"AWS CLI v2"* ]]
}

@test "mc-whitelist rejects a name Minecraft would not allow" {
  run "$BIN/mc-whitelist" "bad name;rm"
  [ "$status" -eq 2 ]
  [ ! -e "$STUB_DIR/aws-calls" ]
}

@test "ssm_run stops when send-command fails" {
  touch "$STUB_DIR/ssm-fails"
  run ssm_run "echo hi"
  [ "$status" -ne 0 ]
  ! grep -q "get-command-invocation" "$STUB_DIR/aws-calls"
}