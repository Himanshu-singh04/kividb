# Benchmark EC2 infra

Self-contained Terraform + CI glue for the two-instance (server + client)
AWS benchmark topology used by `.github/workflows/benchmark.yml` and
`.github/workflows/solo-benchmark.yaml`. Everything under this directory is
independent of any other repo — it does not read from or write to
`kivi-benchmark`, and nothing outside this directory is required to run it.

```
infra/benchmark-ec2/
└── terraform/
    ├── main.tf, variables.tf, outputs.tf, versions.tf
    ├── terraform.tfvars.example
    └── user_data/
        ├── server.sh.tftpl   # OS prep + warm KiviDB/Dragonfly/Redis binaries
        └── client.sh.tftpl   # memtier_benchmark + Rust + optional GH runner
```

## What it provisions

- One **server** instance (default `c7gn.12xlarge`) and one **client**
  instance (default `c7gn.16xlarge`), same AZ, optionally in a cluster
  placement group — mirrors the Dragonfly `c7gn` benchmark topology.
- A security group scoped to SSH (from `ssh_cidr`) and Redis-protocol ports
  6379-6380 between the two instances.
- An `aws_key_pair` built from a public key you pass in (`ssh_public_key`) —
  no pre-existing AWS key pair needs to be created by hand.
- Optionally (`register_github_runner = true`), the client's startup script
  installs `actions/runner` and self-registers as an **ephemeral** GitHub
  Actions self-hosted runner (`--ephemeral`: it takes exactly one job, then
  deregisters itself and exits). CI sets a unique `run-<id>` label so each
  workflow run's job can only land on the instance created for that run.

## CI usage (how the workflows drive this)

The CI jobs (see `.github/workflows/_benchmark-create.yml`) do, in order:

1. Write `secrets.BENCHMARK_SSH_PRIVATE_KEY` to a fixed path and derive its
   public key with `ssh-keygen -y` — this keeps every downstream SSH
   command's `-i <path>` identical run to run, whether the key is generated
   once and stored as a secret or rotated by hand.
2. Mint a runner registration token via the GitHub API using
   `secrets.GH_RUNNER_PAT` (a PAT with **Administration: write** on this
   repo — the default `GITHUB_TOKEN` cannot call this endpoint).
3. `terraform apply` with that public key, the registration token, and
   `run_id = github.run_id`.
4. The `benchmark` job's `runs-on` includes `run-${{ github.run_id }}`, so
   GitHub Actions queues it until the freshly-booted client registers.
5. `.github/workflows/_benchmark-destroy.yml` tears everything down by the
   resource IDs threaded through as job outputs when create finished, and by
   `tag:RunId` when create was cancelled mid-apply (Terraform never exported
   IDs). It uses the AWS CLI rather than `terraform destroy` so jobs do not
   have to share a `.tfstate` file. `terraform apply`'s state is local to
   the `create-instances` job and is discarded when that runner is torn down.

## "Server still creating" hang

Terraform is waiting for the instance to leave `pending`. That is almost
always **cluster placement group + c7gn capacity**, not cloud-init:

- Both instances go in `kividb-benchmark-<run>-cluster-<az>` with strategy
  `cluster`. AWS places them on the same rack.
- The client (`c7gn.16xlarge`) often becomes `running` first and occupies
  that rack. The server (`c7gn.12xlarge`) then sits in `pending` until the
  create timeout (20m) because there is no remaining slot on that hardware.
- CI uses `secrets.AWS_ACCESS_KEY_BENCHMARK`. Your laptop AWS profile is a
  different account, so the pending instance will not show up there.

**What to do**

1. Run **Solo Benchmark** with `use_placement_group` left **off** (the
   workflow default). Same AZ, no cluster rack constraint. Numbers will be
   a few microseconds higher than a cluster-PG run; throughput still matches
   the Dragonfly topology.
2. If you need cluster PG for published latency, keep it on and retry a
   different `availability_zone` (`us-east-1a` / `1b` / `1d` / `1f`).
3. Do not cancel at 90s. If it is still pending after ~5 minutes it will
   not recover — let the 20m timeout fail so destroy can run. Destroy now
   finds leftovers by `RunId` even when apply never exported instance IDs.
4. To inspect a stuck run, open the **benchmark** AWS account (the one
   behind `AWS_ACCESS_KEY_BENCHMARK`) and look at instance state reason
   (`Insufficient instance capacity` / placement group).

## Manual / local usage

```bash
cd infra/benchmark-ec2/terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: run_id, ssh_public_key, ssh_cidr, region.
# Leave register_github_runner unset/false for a plain client instance.

terraform init
terraform apply

# ... use the instances (see outputs for IPs) ...

terraform destroy
```

Bootstrap logs on each instance: `/var/log/user-data-server.log` and
`/var/log/user-data-client.log`. Runner logs (when
`register_github_runner = true`): `/home/ubuntu/actions-runner.log`.

The runner release installed is whichever is current when the instance boots
(`github_runner_version = "latest"`). GitHub stops accepting registrations
from runners older than a minimum it raises every few months, so a pinned
version works until one day it does not: pin one only for a reason, and keep
it up to date.

In CI, the `create-instances` job waits for the runner to come online and
fails after 20 minutes if it has not, printing the end of the client's
console output. Without that, a bootstrap that fails leaves the benchmark job
queued for a runner that will never exist — for hours, with both instances
running.

## Required GitHub secrets/vars for the CI workflows

| Name | Where | Purpose |
|------|-------|---------|
| `AWS_ACCESS_KEY_BENCHMARK` / `AWS_ACCESS_SECRET_BENCHMARK` | secret | AWS credentials for creating/destroying instances |
| `BENCHMARK_SSH_PRIVATE_KEY` | secret | PEM private key; its public half is installed on both instances each run |
| `GH_RUNNER_PAT` | secret | Fine-grained PAT, **Administration: write** on this repo, used only to mint short-lived runner registration tokens |

No `BENCHMARK_SERVER_INSTANCE_ID` / `BENCHMARK_CLIENT_INSTANCE_ID` /
`SERVER_PRIVATE_IP` repo vars are needed anymore — instances are created
and destroyed within each workflow run.
