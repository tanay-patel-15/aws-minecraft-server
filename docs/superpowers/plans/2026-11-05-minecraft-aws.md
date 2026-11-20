# Minecraft Server on AWS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Terraform-managed vanilla Minecraft server on AWS that starts with one command, keeps the world across stops, and spends no real money.

**Architecture:** Two Terraform roots. `infra/storage` holds the long-lived S3 bucket and budget. `infra/server` holds the VPC, instance, data volume, and Elastic IP. Scripts in `instance/` are uploaded to S3 and synced on every boot, so script changes never replace the instance. Commands in `bin/` run on the owner's Mac.

**Tech Stack:** Terraform (AWS provider), Amazon Linux 2023, systemd, Bash, AWS CLI v2, SSM, S3, bats-core, shellcheck.

**Spec:** `docs/superpowers/specs/2026-11-05-minecraft-aws-design.md`

## Global Constraints

- Region `us-east-1`. Every tool uses AWS profile `minecraft`.
- Never use AWS Organizations, Control Tower, or IAM Identity Center. Never upgrade the plan. If a service is unavailable, stop and ask the owner.
- Instance `c7i-flex.large`. Shutdown behavior `stop`, never `terminate`.
- Inbound: TCP 25565 from the owner's current IP `/32` only. No SSH, no key pair, no NAT gateway.
- Minecraft: latest release at install time, pinned afterwards. Java major and jar SHA-1 come from Mojang metadata.
- Never commit Terraform state, `.terraform/`, `*.tfvars`, keys, or the owner's email or IP.
- Do not commit or push unless the owner asks. "Offer a commit" below means ask.
- The owner reviews the plan output and approves every `terraform apply` and `destroy`.
- Stop if any plan shows the instance or data volume being replaced, unless the task expects it.
- Teaching: explain each resource as it is added.

## Review Focus

1. Home IP changes between sessions: `mc-start` adds the new IP and removes the old rule. (Task 5)
2. `mc-start` runs while the instance is stopping or already running: it waits or reuses it, and never errors. (Task 5)
3. Backup fails partway: `save-on` is restored, the partial file is not uploaded, and shutdown still completes. (Task 6)
4. Empty data volume, backups exist, but restore fails: Minecraft must not start a new world. (Task 6)
5. A player connects just before the idle limit: the idle clock resets. (Task 7)

---

## File Structure

```
.gitignore  README.md
bin/      lib.sh mc-start mc-stop mc-status mc-whitelist mc-download-world mc-teardown
infra/storage/  versions.tf variables.tf main.tf budget.tf outputs.tf
infra/server/   versions.tf variables.tf network.tf compute.tf iam.tf scripts.tf outputs.tf
instance/ mc-boot.sh mc-install.sh minecraft.service minecraft.socket mc-boot.service
          mc-backup.sh mc-backup.service mc-backup.timer
          idle_check.sh mc-idle.sh mc-idle.service mc-idle.timer
tests/    idle_check.bats backup.bats install.bats mc_start.bats stubs/
```

Paths on the instance: scripts in `/opt/mc`, data volume at `/srv/minecraft`, console FIFO at `/run/minecraft.stdin`, system user `minecraft`.

### Task 1: Tools, repo, and upgrade check

**Files:**
- Create: `.gitignore`

**Interfaces:**
- Produces: a git repo and working `terraform`, `bats`, and `shellcheck` commands.

- [ ] **Step 1: Confirm the real AWS CLI**

Run: `aws --version`
Expected: starts with `aws-cli/2`. If not, ask the owner to remove the stray Miniconda `aws` package.

- [ ] **Step 2: Install tools**

Run: `brew tap hashicorp/tap && brew install hashicorp/tap/terraform bats-core shellcheck`
Expected: `terraform version` prints a version.

- [ ] **Step 3: Check upgrade triggers on the live page**

Read https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/free-tier-plans.html and the Free plan service list. Confirm EC2, EBS, VPC, S3, SSM, IAM, and Budgets do not trigger an upgrade and are available. Verify prices for `c7i-flex.large`, public IPv4, and gp3.
Expected: all clear, reported to the owner. Otherwise stop.

- [ ] **Step 4: Create the repo and `.gitignore`**

Run `git init -b main`. Ignore `.terraform/`, `*.tfstate*`, `*.tfvars`, `*.pem`, and `.env`. Keep `.terraform.lock.hcl` tracked.

- [ ] **Step 5: Offer a commit**

### Task 2: Storage and budget

**Files:**
- Create: `infra/storage/versions.tf`, `variables.tf`, `main.tf`, `budget.tf`, `outputs.tf`, and untracked `terraform.tfvars`

**Interfaces:**
- Produces: output `bucket_name`, read by Task 3 through `terraform_remote_state` (local backend, `../storage/terraform.tfstate`).

- [ ] **Step 1: Write the provider config**

Pin the AWS provider to a major version. Use `profile = "minecraft"`, `region = "us-east-1"`, and `default_tags` with `Project = "minecraft"`.

- [ ] **Step 2: Define the bucket**

Bucket name prefix `minecraft-world-`. Versioning on, all public access blocked, SSE-S3 encryption, `force_destroy = true` (Task 8 guards deletion). Lifecycle: expire `backups/` objects after 30 days and noncurrent versions after 7 days.

- [ ] **Step 3: Define the budget**

`aws_budgets_budget`, monthly `COST`, limit `5` USD, with `cost_types { include_credit = false }` so usage covered by credits still counts. Email notifications at 50% and 100% ACTUAL. Variable `alert_email` has no default. Set it in `terraform.tfvars` to the address the owner gave in chat.

- [ ] **Step 4: Validate**

Run: `terraform -chdir=infra/storage init && terraform -chdir=infra/storage fmt -check && terraform -chdir=infra/storage validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 5: Review and apply**

Run `terraform -chdir=infra/storage plan`, walk the owner through it, then apply on approval.
Expected: `bucket_name` is output and the budget shows in the console.

- [ ] **Step 6: Offer a commit**

### Task 3: Network

**Files:**
- Create: `infra/server/versions.tf`, `variables.tf`, `network.tf`, `outputs.tf`

**Interfaces:**
- Consumes: `bucket_name` from Task 2.
- Produces: `aws_subnet.public`, `aws_security_group.minecraft`, `aws_eip.minecraft`; outputs `public_ip`, `security_group_id`.

- [ ] **Step 1: Define the network**

VPC `10.0.0.0/16`, one public subnet `10.0.1.0/24`, internet gateway, route table. Choose the subnet's AZ with `data.aws_ec2_instance_type_offerings` filtered to `c7i-flex.large`, so the instance type is available there.

- [ ] **Step 2: Define the security group and Elastic IP**

Security group with all egress allowed and no `ingress` blocks. `mc-start` owns the ingress rule, and leaving out the blocks means Terraform does not revert it. Add `aws_eip.minecraft` with `domain = "vpc"`.

- [ ] **Step 3: Validate, review, apply**

Run the Task 2 validate command against `infra/server`, then plan and apply on approval.
Expected: `public_ip` is output, and a second `plan` reports no changes.

- [ ] **Step 4: Offer a commit**

### Task 4: Instance, data volume, and Minecraft

**Files:**
- Create: `infra/server/compute.tf`, `iam.tf`, `scripts.tf`
- Create: `instance/mc-boot.sh`, `mc-install.sh`, `mc-boot.service`, `minecraft.service`, `minecraft.socket`
- Test: `tests/install.bats`

**Interfaces:**
- Consumes: Task 3 resources and `bucket_name`.
- Produces: output `instance_id`; `/opt/mc/config.env` with `BUCKET`, `VOLUME_ID`, `EULA`; console FIFO `/run/minecraft.stdin`; `mc-install.sh` function `resolve_version PIN_FILE MANIFEST_JSON` printing the version to install.

- [ ] **Step 1: Write the failing tests**

In `tests/install.bats`, using a fixture manifest:
- `resolve_version uses latest release when no pin exists`
- `resolve_version keeps the pinned version when a newer release exists`

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/install.bats`
Expected: FAIL, `resolve_version` not found.

- [ ] **Step 3: Implement `mc-install.sh`**

Must be safe to re-run on every boot, and only run its main steps when executed directly so the tests can source it.
- Format the data volume only if `blkid` finds no filesystem. Find it through `/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${VOLUME_ID without the dash}`. Mount at `/srv/minecraft` by label `mcdata` with `nofail`.
- Pin file is `/srv/minecraft/version.txt`. It lives on the data volume, so it travels with backups.
- Install `java-<major>-amazon-corretto-headless`, with the major from version metadata. Install `jq`.
- Download `server.jar` only if missing or the version changed. Fail on SHA-1 mismatch.
- Write `eula.txt` from `EULA`. Refuse to continue unless it is `true`.
- If `server.properties` is missing, write `white-list=true`, `enforce-whitelist=true`, `online-mode=true`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/install.bats && shellcheck instance/*.sh`
Expected: PASS.

- [ ] **Step 5: Write the systemd units**

- `mc-boot.service`: oneshot with `RemainAfterExit=yes`, after `network-online.target`, before `minecraft.service`. Runs `mc-boot.sh`, which syncs `s3://$BUCKET/scripts/` to `/opt/mc`, installs the units, and runs `mc-install.sh`.
- `minecraft.socket`: `ListenFIFO=/run/minecraft.stdin`.
- `minecraft.service`: user `minecraft`, `WorkingDirectory=/srv/minecraft`, `After=network-online.target mc-boot.service`, `Requires=mc-boot.service`, `StandardInput=socket`, `StandardOutput=journal`, `ExecStart=java -Xms2G -Xmx3G -jar server.jar nogui`, `SuccessExitStatus=143`, `TimeoutStopSec=300`, `Restart=on-failure`. SIGTERM makes vanilla save and exit.

- [ ] **Step 6: Define the Terraform resources**

- `scripts.tf`: `aws_s3_object` for each `instance/` file at `scripts/<name>` (use `for_each = fileset`, and `etag = filemd5`), plus `scripts/config.env` built from variables. Variable `accept_minecraft_eula` is a bool with no default, set by the owner in their tfvars.
- `iam.tf`: instance role with `AmazonSSMManagedInstanceCore`, plus a policy limited to this bucket: read `scripts/*`, read and write `backups/*`, and list the bucket. No other permissions.
- `compute.tf`: AL2023 x86_64 AMI through the public SSM parameter, encrypted gp3 root at the AMI's default size, `instance_initiated_shutdown_behavior = "stop"`, IMDSv2 required, `lifecycle { ignore_changes = [ami, user_data] }`. `user_data` only downloads `mc-boot.sh` and `mc-boot.service` and enables the service. Separate 10 GB gp3 `aws_ebs_volume` and `aws_volume_attachment`. `aws_eip_association`.

- [ ] **Step 7: Review and apply**

Have the owner read the EULA and set `accept_minecraft_eula = true`. Run plan, then apply on approval.
Expected: output `instance_id`.

- [ ] **Step 8: Verify on the instance**

Run: `aws ssm start-session --target <instance_id> --profile minecraft`, then `systemctl status minecraft` and `journalctl -u minecraft | grep 'Done ('`
Expected: `active (running)` and a `Done (` line. `free -m` shows memory headroom.

- [ ] **Step 9: Offer a commit**

### Task 5: Start, stop, and whitelist commands

**Files:**
- Create: `bin/lib.sh`, `bin/mc-start`, `bin/mc-stop`, `bin/mc-status`, `bin/mc-whitelist`
- Test: `tests/mc_start.bats`, `tests/stubs/aws`, `tests/stubs/curl`

**Interfaces:**
- Consumes: outputs `instance_id`, `public_ip`, `security_group_id`.
- Produces: `lib.sh` functions `require_aws_cli`, `tf_output NAME`, `instance_state`, `ssm_run COMMAND` (prints stdout, returns the remote exit code), `sync_ingress CURRENT_IP`.

- [ ] **Step 1: Write the failing tests**

The stubs record calls to a log and return scripted responses.
- `sync_ingress replaces an old IP rule with the current IP`
- `sync_ingress makes no change when the rule already matches`
- `mc-start waits when the instance is stopping, then starts it`
- `mc-start does not call start-instances when already running`
- `require_aws_cli fails clearly when aws is not aws-cli/2`

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/mc_start.bats`
Expected: FAIL.

- [ ] **Step 3: Implement the commands**

- `sync_ingress`: get the IP from `https://checkip.amazonaws.com`, then remove every other port 25565 rule and add the `/32` rule.
- `mc-start`: `require_aws_cli`, sync ingress, wait out `stopping`, start if `stopped`, wait for `instance-running`, poll `ssm_run "journalctl -u minecraft -b | grep -q 'Done ('"` every 5 seconds for up to 5 minutes, then print `Server ready: <public_ip>`. Use the log check, because Minecraft opens its port before the world finishes loading.
- `mc-stop`: `stop-instances`, then wait for `instance-stopped`. Safe when already stopped.
- `mc-status`: print state, IP, and credits remaining from `aws freetier get-account-plan-state`.
- `mc-whitelist NAME`: validate `^[A-Za-z0-9_]{3,16}$`, then `ssm_run` writes `whitelist add NAME` to the FIFO.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/mc_start.bats && shellcheck bin/*`
Expected: PASS.

- [ ] **Step 5: Teach the whitelist, then test for real**

The owner gave no username yet, so teach them `bin/mc-whitelist <name>` here and have them run it.
Run: `bin/mc-stop`, `bin/mc-start`, then join from a 26.3 client (or the pinned version).
Expected: prints `Server ready:` and the owner joins. Build something, run `bin/mc-stop`, `bin/mc-start`, rejoin, and see it still there.

- [ ] **Step 6: Offer a commit**

### Task 6: Backup and restore

**Files:**
- Create: `instance/mc-backup.sh`, `mc-backup.service`, `mc-backup.timer`
- Modify: `instance/mc-install.sh`, `instance/minecraft.service`
- Test: `tests/backup.bats`

**Interfaces:**
- Consumes: FIFO, `config.env`.
- Produces: objects at `s3://$BUCKET/backups/world-YYYYMMDDTHHMMSSZ.tar.gz`; `mc-backup.sh --live|--offline`; `mc-install.sh` function `restore_if_empty`.

- [ ] **Step 1: Write the failing tests**

Using stubs for `aws` and the console:
- `live backup sends save-off then save-all flush, and save-on after tar`
- `live backup sends save-on when tar fails, and uploads nothing`
- `offline backup exits 0 when upload fails, so shutdown continues`
- `restore_if_empty extracts the newest backup into an empty directory`
- `restore_if_empty does nothing when a world exists`
- `restore_if_empty creates no world and exits non-zero when backups exist but download fails`
- `restore_if_empty exits 0 when there are no backups`

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/backup.bats`
Expected: FAIL.

- [ ] **Step 3: Implement**

- `--live`: use a `trap` to guarantee `save-on`. Wait up to 60 seconds for `Saved the game` in the journal. Tar to `/tmp`, then upload.
- `--offline`: no console commands. Skip the backup if `world/` is missing. Log failures and exit 0.
- Each archive holds `world/`, `whitelist.json`, `ops.json`, `server.properties`, `version.txt`.
- `restore_if_empty`: runs before the jar step, so `version.txt` restores the pin. A non-zero exit stops `minecraft.service` through `Requires=`.
- `mc-backup.timer`: every 30 minutes, `PartOf=minecraft.service`, running `--live`.
- `minecraft.service`: add `ExecStopPost=/opt/mc/mc-backup.sh --offline`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/backup.bats && shellcheck instance/*.sh`
Expected: PASS.

- [ ] **Step 5: Deploy and verify a stop-time backup**

Apply on approval (only `aws_s3_object` changes expected). Run `bin/mc-stop`, `bin/mc-start`, `bin/mc-stop`, then list `backups/`.
Expected: a new archive from the last stop, with a non-trivial size. If EC2 stops the instance before the upload finishes, have `bin/mc-stop` run `ssm_run "systemctl stop minecraft"` first.

- [ ] **Step 6: Offer a commit**

### Task 7: Idle auto-shutdown (owner writes the core)

**Files:**
- Create: `instance/idle_check.sh`, `mc-idle.sh`, `mc-idle.service`, `mc-idle.timer`
- Test: `tests/idle_check.bats`

**Interfaces:**
- Produces: `should_stop PLAYERS IDLE_MINUTES UPTIME_MINUTES`, returning 0 to shut down and 1 to keep running. Constants `IDLE_LIMIT_MINUTES=15` and `BOOT_GRACE_MINUTES=15`.

- [ ] **Step 1: Write the failing tests and a stub for the owner**

`idle_check.sh` holds the signature and a `TODO(owner)` marker only.
- `keeps running while a player is connected`
- `keeps running during the boot grace period`
- `keeps running below the idle limit`
- `stops at exactly the idle limit`
- `stops when past the idle limit with no players`

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/idle_check.bats`
Expected: FAIL.

- [ ] **Step 3: The owner implements `should_stop`**

Explain the trade-offs, then let the owner write the 5 to 10 lines. Do not write it for them. Review it afterwards.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/idle_check.bats`
Expected: PASS.

- [ ] **Step 5: Implement the wrapper**

`mc-idle.sh` runs each minute from the timer. It counts established connections with `ss -Htn state established '( sport = :25565 )'`, keeps the last-active time in `/run/mc-idle/last-active` (reset whenever players are above 0), and calls `systemctl poweroff` when `should_stop` returns 0. `/run` clears on boot, so a missing file starts the clock at the current time.

- [ ] **Step 6: Deploy and verify**

Apply on approval, then run `bin/mc-start`, stay off the server, and wait about 15 to 20 minutes.
Expected: `mc-status` shows `stopped`, a new backup exists, and the world resumes on the next start.

- [ ] **Step 7: Offer a commit**

### Task 8: Rebuild drill and teardown

**Files:**
- Create: `bin/mc-download-world`, `bin/mc-teardown`

**Interfaces:**
- Consumes: `lib.sh`, outputs from both roots.

- [ ] **Step 1: Implement the commands**

- `mc-download-world`: download the newest backup to `./world-backups/` and add that folder to `.gitignore`.
- `mc-teardown --server`: run `mc-stop`, confirm a backup newer than the stop exists, then `terraform destroy` on `infra/server`.
- `mc-teardown --all`: run `--server`, run `mc-download-world`, require typing `delete my backups`, then destroy `infra/storage`.

- [ ] **Step 2: Run the rebuild drill**

Run `bin/mc-teardown --server`, re-apply `infra/server` on approval, then run `bin/mc-start`. The whitelist comes back with the backup, so don't re-add the owner.
Expected: the Elastic IP is new, so update the Multiplayer entry. The owner joins and the build is still there, on the same Minecraft version as before.

- [ ] **Step 3: Offer a commit**

### Task 9: Finish for the resume

**Files:**
- Modify: `README.md`, `docs/superpowers/specs/2026-11-05-minecraft-aws-design.md` if behavior changed

- [ ] **Step 1: Replace `AdministratorAccess`**

Write a least-privilege policy for `minecraft-admin` covering what the project uses. Have the owner attach it, then run a plan and `bin/mc-status`.
Expected: both work. Keep the old policy available until confirmed.

- [ ] **Step 2: Record real costs**

Compare credits with the $100.00 start, and read Billing for actual usage.

- [ ] **Step 3: Write the README**

Architecture diagram, decisions and why, measured costs, how to run it, what you'd change next, and the interview summary using real numbers.

- [ ] **Step 4: Remind the owner of the deadline**

Everything must be deleted with `bin/mc-teardown --all` before 2027-05-06.
Run after teardown: `aws ec2 describe-addresses --profile minecraft` and `aws ec2 describe-volumes --profile minecraft`
Expected: both lists empty.

- [ ] **Step 5: Offer a commit, and offer to create the GitHub repo**
