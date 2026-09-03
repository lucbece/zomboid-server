# Deploying to Oracle Cloud

This document covers everything specific to running the server on Oracle Cloud Infrastructure
(OCI): the account, the API key, the deployment itself, costs, and the failure modes that only
happen on this provider. Provider-independent operation is in [`runbook.md`](runbook.md); the
component layout is in [`architecture.md`](architecture.md).

The deployment is driven by OpenTofu. `./setup.sh` writes the configuration,
`make deploy` applies it and waits until the game is up.

## What gets created

| Resource | Purpose |
|---|---|
| Compartment | Isolates every resource of the project |
| VCN, public subnet, internet gateway, route table | Network |
| Network security group | UDP 16261-16262 from anywhere; TCP 22 and 27015 from the administrator's address only |
| `VM.Standard.E5.Flex` instance, Ubuntu 24.04 | The VM. Size chosen by `setup.sh` from the player count |
| Reserved public IP | A fixed address that survives stop/start |
| Object Storage bucket + lifecycle rule | Off-machine backups, deleted after `backup_retention_days` (30 by default) |
| Dynamic group + IAM policy | Lets the VM write to the bucket by instance principal, with no credentials on disk |
| Budget + two alert rules | Email at 80% forecast and 100% actual spend |

The VM's boot volume is deleted with the instance. The state that matters lives in git and in the
backup bucket.

## 1. Oracle Cloud account

### 1.1 Sign up

1. Create the account at <https://www.oracle.com/cloud/free/>.
2. Choose the **home region** carefully. It cannot be changed later, and it determines where the
   server will live. Pick the one closest to the players.

   | Players in | Region | Approximate latency |
   |---|---|---|
   | Argentina, Uruguay, Chile, Brazil | Brazil East (São Paulo) | ~30 ms |
   | Argentina or Chile | Chile Central (Santiago) | ~25-35 ms |
   | US East Coast | US East (Ashburn) | ~20 ms |
   | US West Coast | US West (Phoenix) | ~20 ms |
   | Spain | Spain Central (Madrid) | ~20 ms |
   | Rest of Europe | Germany Central (Frankfurt) | ~20 ms |
   | United Kingdom | UK South (London) | ~15 ms |

   Not every region is offered at sign-up; the list depends on the account and the country.
3. Verify the email address and add a payment card. Sign-up places a small authorization on the
   card, which is reversed.
4. Wait for the confirmation that the account is ready. Provisioning a new tenancy takes
   anywhere from ten minutes to several hours. Nothing below works until it completes.

### 1.2 Upgrade to Pay As You Go

Free Tier accounts cannot create the paid `E5.Flex` shape: the deployment fails with
`LimitExceeded` or `NotAuthorizedOrNotFound`.

In the console: account menu (top right) → **Upgrade to Paid**, or *Billing & Cost Management* →
*Upgrade and Payment*.

Two things to expect:

- Oracle places a **100 USD authorization** on the card as a verification step. It is an
  authorization, not a charge, and it is reversed; the bank may show it as pending for a few
  days. Cards without international purchases enabled are declined.
- The upgrade itself can take from a few hours to a couple of days to complete. The console keeps
  reporting the account as Free Tier until it does.

Once upgraded, check under *Governance & Administration → Limits, Quotas and Usage* that the
limit "Cores for Standard.E5.Flex" in your region is above zero. If it is zero, request an
increase; it is free and usually granted within hours.

### 1.3 Create the API key

The API key is what authorizes OpenTofu to create resources in the account. The simplest path is
to generate the key pair locally and upload only the public half, which avoids handling a
downloaded private key file.

```bash
mkdir -p ~/.oci && chmod 700 ~/.oci
openssl genrsa -out ~/.oci/oci_api_key.pem 2048
chmod 600 ~/.oci/oci_api_key.pem
openssl rsa -pubout -in ~/.oci/oci_api_key.pem -out ~/.oci/oci_api_key_public.pem
cat ~/.oci/oci_api_key_public.pem
```

In the console: profile icon → **My profile** → **API keys** → **Add API key** → **Paste a public
key**. Paste the block printed by the last command, including the `-----BEGIN PUBLIC KEY-----`
and `-----END PUBLIC KEY-----` lines, and click **Add**.

The console then shows a configuration preview with `user`, `fingerprint`, `tenancy` and
`region`. Copy it into `~/.oci/config` and add a `key_file` line pointing at the private key:

```ini
[DEFAULT]
user=ocid1.user.oc1..aaaa...
fingerprint=aa:bb:cc:...
tenancy=ocid1.tenancy.oc1..aaaa...
region=sa-saopaulo-1
key_file=/home/YOUR_USER/.oci/oci_api_key.pem
```

```bash
chmod 600 ~/.oci/config
```

`key_file` must be an absolute path. The `tenancy` value is also what goes into `tenancy_ocid`
in `terraform.tfvars`.

To confirm the fingerprint shown in the console matches the local key:

```bash
openssl rsa -pubout -outform DER -in ~/.oci/oci_api_key.pem | openssl md5 -c
```

The alternative flow — leaving **Generate API key pair** selected, clicking **Download private
key**, and moving the downloaded `.pem` to `~/.oci/oci_api_key.pem` with mode 600 — produces the
same result.

## 2. `./setup.sh`

```bash
git clone https://github.com/lucbece/zomboid-server.git
cd zomboid-server
./setup.sh
```

The wizard:

- checks for `git`, `curl`, `make`, `ssh`, `rsync` and bash 4 or newer;
- offers to install OpenTofu into `~/.local/bin` (checksum-verified) and the `oci` CLI into
  `~/.venvs/oci`, neither of which needs `sudo`;
- generates the three passwords as four-token strings such as `arena-tulipan-molino-4821`, which
  satisfy the module's validation rules and are easy to dictate;
- detects your public IP address, your SSH public key, the API key and the region;
- asks for the server name, the maximum number of players, an email address for spend alerts and
  the monthly budget threshold.

It writes two files and nothing else:

- `infra/terraform/envs/prod/terraform.tfvars` — read by OpenTofu, mode 600, git-ignored.
- `.env` — the local server configuration, mode 600, git-ignored. The VM's own `.env` is
  generated separately by cloud-init from `terraform.tfvars`.

It is safe to re-run. Existing answers become the defaults, so only what you change is changed.
Re-running is the normal way to update `admin_cidr` after your ISP changes your public IP.

### Machine size

`setup.sh` derives the shape from `max_players`:

| Players | OCPUs | RAM | JVM heap (`max_memory`) |
|---|---|---|---|
| up to 8 | 2 | 12 GB | 8g |
| more than 8 | 4 | 16 GB | 12g |

Set `ZS_OCPUS` and `ZS_MEMORY_GB` to override; the heap is then computed as the machine's RAM
minus 4 GB, which is reserved for the operating system and Docker. The values end up in
`terraform.tfvars` and can also be edited there directly.

`--no-preguntar` runs the wizard non-interactively, taking every answer from the `ZS_*`
environment variables. It is used by tests and CI.

### Checking before you deploy

```bash
make doctor
```

Each line reports `OK`, `AVISO` (warning) or `FALTA` (missing), with the action to take
underneath. It verifies the local tools, the SSH key, `~/.oci/config` and its `key_file`, a real
API call, the completeness and permissions of `terraform.tfvars` and `.env`, and the reachability
of `repo_url`. When a state file already exists it also reports the instance state and the most
recent backup in the bucket.

## 3. `make deploy`

```bash
make deploy
```

It lists what will be created, states that billing starts from that point, and asks for
confirmation once. The steps are:

1. run `scripts/doctor.sh` and stop if something blocking is missing;
2. `tofu init`;
3. if the repository is private, create the deploy key and register it on GitHub;
4. `tofu apply` — resources are created here;
5. wait for SSH to answer (up to 10 minutes);
6. wait for the game to finish installing and start (up to 30 minutes);
7. print the address, port and server password.

The first run takes 20 to 40 minutes in total: `tofu apply` is 2 to 4 minutes, and cloud-init
then performs a package upgrade and pulls a 10.4 GB image. Interrupting with Ctrl+C is safe; the
step is resumed on the next `make deploy`.

Options:

- `make deploy YES=1` — skip the confirmation prompt.
- `make deploy DRY_RUN=1` — print the steps without executing anything.
- `ESPERA_SSH_SEG` and `ESPERA_JUEGO_SEG` — timeouts, in seconds (600 and 1800 by default).

`make deploy` is idempotent. Running it on an unchanged deployment changes nothing and reprints
the connection details.

### Following the provisioning by hand

```bash
ssh pz@$(tofu -chdir=infra/terraform/envs/prod output -raw public_ip)
sudo cloud-init status --wait
sudo tail -f /var/log/cloud-init-output.log
cd /opt/zomboid-server && make logs
```

### Which repository the VM clones

cloud-init clones a repository into `/opt/zomboid-server`. `setup.sh` picks the right mode by
testing `git ls-remote` without credentials:

| `repo_url` | Behaviour | Manual step |
|---|---|---|
| `https://…` (public) | Anonymous clone. No key pair is generated and no private key ever reaches the VM | none |
| `git@github.com:…` (private) | OpenTofu generates an ed25519 pair and injects the private half | Register the public half as a read-only deploy key |
| unset | Clones the public upstream | none; your own configuration is pushed with `make sync` |

With a private repository the deploy key must exist on GitHub **before** the first boot, or
cloud-init fails to clone. `make deploy` handles the ordering, using the `gh` CLI when it is
authenticated. By hand:

```bash
tofu -chdir=infra/terraform/envs/prod apply -target=module.zomboid.tls_private_key.deploy
tofu -chdir=infra/terraform/envs/prod output -raw deploy_public_key
# paste into GitHub -> repository -> Settings -> Deploy keys, without write access
make infra-apply
```

### Keeping your own configuration

Using this repository as-is works: the VM clones the upstream and `make sync` pushes your local
changes to it. Those changes do not survive rebuilding the VM, though. To make them permanent,
fork the repository, point `origin` at the fork, commit `config/`, and re-run `./setup.sh` so it
picks up the new URL.

## 4. Day-to-day operation

These targets run from the administrator's machine against the VM. The address is read from the
OpenTofu state; pass `VM_IP=…` to override it.

| Command | What it does |
|---|---|
| `make remote-status` | Container state and connected players |
| `make remote-logs` | Follow the server log |
| `make remote-up` / `make remote-down` | Start or cleanly stop the game (the VM stays up) |
| `make remote-restart` | Clean restart; applies config and mod changes |
| `make remote-rcon CMD=players` | Any admin command over RCON |
| `make remote-backup` | Force a backup and upload it to the bucket |
| `make sync` | rsync `config/`, `scripts/`, `tools/`, `infra/systemd/`, `Makefile` and `docker-compose.yml` to the VM |
| `make sync RESTART=1` | The same, followed by `make remote-restart` |
| `make doctor` | Prerequisites, instance state and last backup |
| `make deploy` | Apply infrastructure changes and wait for the game to come back |
| `make destroy-all` | Final backup, then delete everything |

`make sync` deliberately excludes `.env`, `data/` and `bin/`: the VM's `.env` is generated by
cloud-init from `terraform.tfvars`, and the rest is machine-local.

There are two ways to get changes onto the VM. `make sync RESTART=1` is the fast path and does
not go through git. Committing, pushing and running `git pull && make restart` on the VM is the
reproducible one.

RCON is bound to `127.0.0.1` inside the VM, so `make remote-rcon` runs it over SSH. For an
interactive session, forward the port:

```bash
ssh -N -L 27015:127.0.0.1:27015 pz@<IP> &
./bin/mcrcon -H 127.0.0.1 -P 27015 -p '<rcon_password>' -t
```

## 5. Stopping and starting the VM

A stopped instance is not billed for compute. The boot volume and the reserved IP remain, so the
world and the address are preserved.

```bash
./scripts/cloud-stop.sh     # clean game shutdown and backup over SSH, then SOFTSTOP
./scripts/cloud-start.sh    # START, then wait for RUNNING
```

Both need the `oci` CLI. `cloud-stop.sh --hard` skips the SSH step, for when SSH is unreachable;
the SOFTSTOP still triggers the systemd unit's `ExecStop`, which saves the world.

`scripts/idle-shutdown.sh` stops and powers off the VM after `IDLE_MINUTES` with no players. It
is written but not scheduled: the cron line in `/etc/cron.d/zomboid` is commented out, because
without a way for players to power the VM back on, an automatic shutdown locks everyone out.
Test it with `DRY_RUN=1 ./scripts/idle-shutdown.sh`.

## 6. Costs and budget

Approximate list prices for `VM.Standard.E5.Flex` as of 2026-09: 0.03 USD per OCPU-hour and
0.002 USD per GB-hour, the same in every region. Verify them before committing — prices change,
and taxes on foreign digital services are applied on top of these amounts in many countries.

| VM size | Per hour | ~20 h/week (~87 h) | ~6 h/day (~180 h) | 24/7 (~730 h) |
|---|---|---|---|---|
| 2 OCPU / 12 GB | 0.084 USD | ~7 USD/month | ~15 USD/month | ~61 USD/month |
| 4 OCPU / 16 GB | 0.152 USD | ~13 USD/month | ~28 USD/month | ~111 USD/month |

Fixed costs on top of compute:

- 80 GB boot volume: about 2 USD/month, billed whether the instance runs or not.
- Backups in Object Storage: cents per month at Standard tier with 30-day retention.
- Reserved public IP: free while it is attached.

OpenTofu creates a monthly budget of `budget_usd` (25 by default) over the tenancy, with two
alerts to `alert_email`: a forecast alert at 80% and an actual-spend alert at 100%. Budget alerts
only send email; they do not stop anything. If the account lacks permissions on the root
compartment, set `enable_budget = false` in `terraform.tfvars` and create the budget by hand.

## 7. Deleting everything

```bash
make destroy-all              # asks you to type the server name to confirm
make destroy-all DRY_RUN=1    # prints the steps without touching anything
```

It reads the address from the state, takes a final backup over SSH if the VM answers,
runs `tofu destroy -auto-approve`, and then reports what is left.

`tofu destroy` cannot delete the Object Storage bucket while it still holds objects, and
therefore cannot delete the compartment either. To leave the account completely clean:

```bash
oci os object bulk-delete --bucket-name zomboid-backups --namespace <namespace>
oci os bucket delete --bucket-name zomboid-backups --namespace <namespace>
```

Then delete the `zomboid` compartment from the console under *Identity → Compartments*.

If there is no local state — the infrastructure was created from another machine — the script
stops and does nothing. Destroy from that machine, or remove the resources from the console.

Rebuilding from scratch is `make infra-destroy`, `make infra-apply`, then a restore from the
bucket. The reserved IP is destroyed and recreated in that cycle, so players have to update the
address in their favourites.

## 8. Troubleshooting

### `make deploy` fails with `LimitExceeded` or `NotAuthorizedOrNotFound`

Either the account is still Free Tier and cannot create a paid shape (see 1.2), or the region in
`terraform.tfvars` is not the account's home region. `make doctor` distinguishes the two.

### Oracle rejects the API key

Check that the first line of `~/.oci/config` is exactly `[DEFAULT]`, that `key_file` is an
absolute path to an existing file, and that the fingerprint in the console matches the local key
(see 1.3). For the underlying error message:

```bash
oci iam region-subscription list
```

### SSH stops working

Almost always the administrator's public IP address changed. Re-run `./setup.sh`, which detects
the new address and rewrites `admin_cidr`, then `make deploy` — it only replaces the security
group rule and does not touch the VM or the world. By hand: update `admin_cidr` in
`terraform.tfvars` and run `make infra-apply`.

If that does not help, check in the console that the instance is `RUNNING`.

### Everything except SSH is blocked on the VM

Oracle's Ubuntu images ship a set of persistent `netfilter-persistent` iptables rules that reject
everything except SSH, and those rules sit in front of ufw's chains, so ufw never gets to decide.
Docker's published ports are unaffected because they traverse `FORWARD`, but any service running
on the host — the rules survey, for example — is silently dropped.

cloud-init disables that persistence and flushes the rules on first boot, so VMs created by the
current code are not affected. On an older VM, apply it manually:

```bash
sudo systemctl disable --now netfilter-persistent
sudo mkdir -p /root/oracle-iptables-backup
sudo cp /etc/iptables/rules.v4 /etc/iptables/rules.v6 /root/oracle-iptables-backup/
sudo rm -f /etc/iptables/rules.v4 /etc/iptables/rules.v6
sudo iptables -P INPUT ACCEPT && sudo iptables -F INPUT
sudo ip6tables -P INPUT ACCEPT && sudo ip6tables -F INPUT
sudo ufw status
```

The OCI network security group keeps filtering from outside regardless.

### The bucket lifecycle rule fails with `InsufficientServicePermissions`

Object Storage deletes expired objects as a service, not as your user, so the compartment needs a
policy statement authorizing it:

```
Allow service objectstorage-<region> to manage object-family in compartment <compartment>
```

The module already emits this statement, along with the dynamic group and the statements that let
the VM read and write the bucket. The error only appears on deployments made before it was added,
or if the policy has not propagated yet.

### Backups do not reach the bucket

```bash
ssh pz@<IP>
rclone lsd oci:
cat /var/log/zomboid/backup.log
```

`NotAuthorizedOrNotFound` means the dynamic group or the policy has not propagated yet — it can
take a few minutes after `apply` — or that the matching rule does not match the instance. Compare
the OCID in *Identity & Security → Domains → Default → Dynamic groups → zomboid-vm-dg* with
`tofu output -raw instance_ocid`.

### cloud-init failed

```bash
ssh pz@<IP>
sudo cloud-init status --long
sudo tail -100 /var/log/cloud-init-output.log
```

Common causes:

- `Permission denied (publickey)` while cloning: only with a private repository. The deploy key
  is missing or wrong. Register the `deploy_public_key` output, then
  `sudo cloud-init clean --logs && sudo reboot`.
- `could not read Username for 'https://github.com'`: `repo_url` is HTTPS but the repository is
  private. Make it public, or re-run `./setup.sh` to switch to SSH plus a deploy key.
- The image pull is slow: it is 10.4 GB, and `docker compose logs` shows nothing until it
  finishes. `TimeoutStartSec` is 1800 seconds.

Game-level problems — version mismatches, mod checksum errors, a corrupted world — are covered in
[`runbook.md`](runbook.md) and [`mods.md`](mods.md).
