# Minecraft Server on AWS: Design

Date: 2026-11-05

## Intent

A personal Java Edition Minecraft server on AWS, built as a resume project. The
owner wants hands-on AWS experience and a project they can explain well in an
interview. The server itself matters less than how it is built and run.

One player (the owner) will use it for about two weeks. After that it can be
deleted. The Terraform code in a GitHub repo is the lasting evidence of the work.

The target interview answer (a draft, suggested by Claude):

> I built a Minecraft server on AWS using only code, so one command creates
> everything and another deletes it. It has no SSH port open, backs up the world
> to S3, shuts itself down when idle, and ran within the free plan.

Cost figures in that answer must come from real measured usage.

## Goals

Stated by the owner:

- Start the server, and receive an IP address to add to Minecraft's Multiplayer
  screen and join through.
- Stop the server with the world saved, then resume from the same world at the
  next start.
- Learn AWS by building this, with teaching along the way.
- Spend no real money.

## Non-goals

- Multiple players, public access, or high availability.
- Mods, plugins, or Paper/Spigot. This is plain vanilla.
- A web page or button for starting the server. One command is enough (Claude's
  call, flagged to the owner).
- A custom domain name.
- CI/CD.

## Anti-goals

The project has failed, even if the server works, if:

- The account is upgraded to a paid plan or any real money is charged.
- The world is lost through a normal stop, start, or infrastructure change.
- A secret (AWS key, Terraform state, RCON password) is committed to the repo.
- The owner cannot explain what was built. Do not hide the work behind magic.

## Constraints

### AWS account

Verified on 2026-11-05 with `aws freetier get-account-plan-state`:

- Plan: `FREE`, status `ACTIVE`, expires 2027-05-06.
- $100.00 in credits. Up to $100 more can be earned through AWS activities.
- Region: `us-east-1`.
- CLI profile: `minecraft` (IAM user `minecraft-admin`, `AdministratorAccess` for
  now). Every tool must use this profile explicitly.

**Hard rule:** AWS's welcome email says the account automatically upgrades to a
paid plan if AWS Organizations "or certain other AWS services and offers" are
used. An upgrade cannot be undone. Do not use Organizations, Control Tower, or IAM
Identity Center. Before using any service not named in this document, check
whether it triggers an upgrade. If a service is unavailable on the Free plan, stop
and ask the owner. Never upgrade to work around it.

Before the first `terraform apply`, confirm against the current AWS "learn more"
page from the email that none of the services in this design trigger an upgrade.

### Local machine

- macOS on Apple Silicon. AWS CLI v2.31.27 is at `/opt/homebrew/bin/aws`.
- A stray PyPI package named `aws` in Miniconda may shadow the real CLI. The owner
  was given a command to remove it. Scripts should fail clearly if `aws --version`
  does not report `aws-cli/2`.
- Terraform is not installed yet and must be installed first.
- The project folder is not yet a git repo and holds only `README.md` and this
  document.

### Minecraft

- Latest release at build time. As of 2026-11-05: version 26.3, needing Java 25.
- Resolve the version at install time from
  `https://piston-meta.mojang.com/mc/game/version_manifest_v2.json`, and take the
  Java major version from that version's metadata instead of hard-coding it.
- Verify the server jar download with the SHA-1 in the metadata.
- Pin the installed version so a restart never silently upgrades the world.
  Upgrading is a deliberate change, because the client must match the server.
- The Minecraft EULA must be accepted by the owner personally. See "Open items".

## Decisions

The owner decided:

- AWS, Java Edition, vanilla, latest release.
- Stop and start preserves the world.
- Join by adding an IP address in Multiplayer.
- No real money spent.

Claude proposed these and the owner raised no objection when they were played
back. Treat them as the design:

| Area | Decision |
|---|---|
| Infrastructure | Terraform for all AWS resources. No console-created resources, apart from the existing IAM user. |
| Instance | `c7i-flex.large` (x86_64, 2 vCPU, 4 GiB), which appears on this account's eligible list |
| Network | A dedicated VPC with one public subnet and an internet gateway. No NAT gateway, because of its cost. |
| Inbound firewall | TCP 25565 from the owner's current IP (`/32`) only. No other inbound ports. |
| Address | An Elastic IP, so the Multiplayer entry never changes |
| Admin access | AWS Systems Manager Session Manager. No SSH port and no key pair. |
| Backups | World archives to a versioned S3 bucket |
| Cost protection | Idle auto-shutdown and an AWS Budgets email alert |
| Game access | Whitelist on, holding only the owner's Minecraft account |

## How it behaves

### Start: one command on the Mac

1. Look up the owner's current public IP.
2. Update the security group rule to allow only that IP. Terraform must not fight
   this change, so the rule's source needs to be excluded from drift, or the
   script must apply it through Terraform.
3. Start the instance.
4. Wait until Minecraft actually accepts connections, not merely until the
   instance is running.
5. Print the address, for example `Server ready: 54.123.45.67`.

The command must be safe to run when the server is already running.

### Stop: one command on the Mac

Tell the server to shut down cleanly and wait until the instance has stopped.

### Clean shutdown

Minecraft runs as a systemd service that starts on boot. A stop must make Minecraft
save and exit before the machine powers off. Allow enough stop timeout for a full
save. All shutdown paths (the stop command, auto-shutdown, and the AWS console) must
use this same path.

### Idle auto-shutdown

Runs on the instance and needs no extra AWS services. If no player has been
connected for a set time, it shuts the machine down using the clean shutdown path.
The instance's shutdown behavior must be `stop`, never `terminate`. There must be a
grace period after boot so the server does not stop before the owner joins.

The owner will write the core idle check themselves as a learning exercise. Prepare
the surrounding file and mark the spot clearly. The default suggestion is 15 minutes.

### Data and durability

- The world lives on a separate EBS data volume, not the root volume. Replacing the
  instance must not delete the world.
- A Terraform change must never silently replace the instance or the data volume.
  Guard against AMI and user-data changes causing replacement.
- Back up the world to S3 on each clean shutdown and on a timer while running. A
  backup must not be taken from a world being written to: use `save-off` and
  `save-all flush`, then `save-on`, or an equivalent.
- The server uses an instance role limited to that one bucket. No AWS keys are stored
  on the instance.
- When the data volume is empty on boot, restore the latest S3 backup if one exists.
  Otherwise, create a new world.

The S3 bucket lives in its own small Terraform root (`infra/storage`), separate from
`infra/server`, so destroying the server does not remove backups. This makes
"destroy, rebuild, resume" work. Deleting backups is a separate, deliberate step.

### Teardown

- `terraform destroy` on `infra/server` removes the server and data volume.
- Destroying `infra/storage` removes the backups. Before that, offer to download the
  latest world to the Mac.
- Everything must be deleted before the Free plan expires on 2027-05-06. Once the
  plan expires, AWS suspends the account and erases it after 90 days unless it is
  upgraded.

## Costs

The figures below are estimates, partly from memory. Verify them before relying on
them, and replace them with measured values for the resume.

| Item | Estimate (from credits) |
|---|---|
| `c7i-flex.large` | About $0.09 per running hour |
| Public IP or Elastic IP | $0.005 per hour, running or stopped |
| EBS gp3 | About $0.08 per GB per month |
| S3, Budgets, Session Manager | Effectively $0 at this scale |

Set a budget alert with a low threshold, such as $5. Actual usage is expected to be a
few dollars of credits. Record real usage from Billing at the end of the project.

## Repo and secrets

- `.gitignore` must cover Terraform state, `.terraform/`, `*.tfvars` containing
  personal data, and any keys.
- Terraform state stays local (Claude's call). This is the simplest setup for one
  person, and the state must never be committed. Remote state in S3 can be noted in
  the README as a possible improvement.
- The README should explain the architecture, costs, and decisions. It is part of what
  an interviewer reads.

## How we work

This is a learning project. Build in small stages, each one working and explained
before the next. Explain the reason for each resource as it is added. Leave a few
meaningful decisions for the owner to write (5 to 10 lines each), such as the idle
check. Do not commit or push unless the owner asks.

## Left to the builder

- Terraform file layout and module structure beyond the two roots.
- The base OS image. Amazon Linux 2023 is suggested, as it includes the SSM agent.
- How to install the Java version required by the Minecraft metadata.
- JVM memory flags, leaving room for the OS on a 4 GiB machine.
- How to detect players for the idle check, and the backup schedule and retention.
- Data volume size (start small, such as 10 GB) and root volume size.
- The scripting language for the start and stop commands.

## Open items for the owner

- Accepting the Minecraft EULA (https://aka.ms/MinecraftEULA) personally. Setting
  `eula=true` is that acceptance, so it should be an explicit Terraform variable that
  the owner sets.
- Providing their Minecraft username for the whitelist.
- Providing the email address for budget alerts.
