# Shared helpers for the bin/ commands. Source this file; don't run it.
# shellcheck shell=bash

export AWS_PROFILE="${AWS_PROFILE:-minecraft}"
export AWS_REGION="${AWS_REGION:-us-east-1}"

MC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MC_PORT=25565
MC_POLL_SECONDS="${MC_POLL_SECONDS:-5}"
MC_READY_TIMEOUT="${MC_READY_TIMEOUT:-300}"

# AWS CLI v1 has different commands and output, so stop early with a clear message.
require_aws_cli() {
  local version
  version=$(aws --version 2>&1) || true
  if [[ "$version" != aws-cli/2* ]]; then
    echo "AWS CLI v2 is required (found: ${version:-nothing})" >&2
    return 1
  fi
}

tf_output() {
  terraform -chdir="$MC_ROOT/infra/server" output -raw "$1"
}

# Reads the three Terraform outputs once. Values already set (as in tests) are kept.
load_outputs() {
  if [[ -z "${INSTANCE_ID:-}" ]]; then INSTANCE_ID=$(tf_output instance_id); fi
  if [[ -z "${SG_ID:-}" ]]; then SG_ID=$(tf_output security_group_id); fi
  if [[ -z "${PUBLIC_IP:-}" ]]; then PUBLIC_IP=$(tf_output public_ip); fi
}

# Prints pending, running, stopping, stopped, and so on.
instance_state() {
  aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].State.Name' --output text
}

# Runs a shell command on the server as root through Session Manager.
# Prints the command's output and returns its exit code.
ssm_run() {
  local command_id result
  command_id=$(aws ssm send-command --instance-ids "$INSTANCE_ID" \
    --document-name AWS-RunShellScript \
    --parameters "$(jq -nc --arg c "$1" '{commands: [$c]}')" \
    --query Command.CommandId --output text) || return 1

  # The waiter fails when the command fails. The exit code is read below, so ignore that.
  aws ssm wait command-executed --command-id "$command_id" \
    --instance-id "$INSTANCE_ID" 2> /dev/null || true

  result=$(aws ssm get-command-invocation --command-id "$command_id" \
    --instance-id "$INSTANCE_ID" --output json) || return 1
  jq -j '.StandardOutputContent' <<< "$result"
  return "$(jq -r '.ResponseCode' <<< "$result")"
}

# Prints this Mac's public IPv4 address, as AWS sees it.
current_ip() {
  local ip
  ip=$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')
  if [[ ! "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    echo "Could not find your public IP (got: '$ip')" >&2
    return 1
  fi
  echo "$ip"
}

# Leaves exactly one Minecraft rule in the firewall: CURRENT_IP/32.
sync_ingress() {
  local want="$1/32" cidr found=no
  for cidr in $(aws ec2 describe-security-groups --group-ids "$SG_ID" \
      --query "SecurityGroups[0].IpPermissions[?FromPort==\`$MC_PORT\`].IpRanges[].CidrIp" \
      --output text); do
    [[ "$cidr" == None ]] && continue
    if [[ "$cidr" == "$want" ]]; then
      found=yes
    else
      aws ec2 revoke-security-group-ingress --group-id "$SG_ID" \
        --protocol tcp --port "$MC_PORT" --cidr "$cidr" > /dev/null
      echo "Firewall: removed old address $cidr"
    fi
  done

  if [[ "$found" == no ]]; then
    aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
      --protocol tcp --port "$MC_PORT" --cidr "$want" > /dev/null
    echo "Firewall: allowed your address $want"
  fi
}