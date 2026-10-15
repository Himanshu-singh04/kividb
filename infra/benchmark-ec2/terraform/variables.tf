variable "aws_region" {
  description = "Region where c7gn is available (e.g. us-east-1, us-west-2)."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefix for resource names."
  type        = string
  default     = "kividb-benchmark"
}

variable "run_id" {
  description = "Unique identifier for this benchmark run (e.g. a CI run id). Used to tag/name resources and, for the client, as an extra self-hosted runner label so jobs land on the instance created for this run."
  type        = string
}

variable "ssh_cidr" {
  description = "CIDR allowed to SSH (port 22) to both instances. Restrict to your IP for production use."
  type        = string
  default     = "0.0.0.0/0"
}

variable "ssh_public_key" {
  description = "SSH public key (authorized_keys format) to install as the EC2 key pair for both instances. The module creates the key pair itself, so no pre-existing AWS key pair is required."
  type        = string
}

variable "server_instance_type" {
  description = "Dragonfly README: Dragonfly server on c7gn.12xlarge (48 vCPU)."
  type        = string
  default     = "c7gn.12xlarge"
}

variable "client_instance_type" {
  description = "Dragonfly README: memtier_benchmark client on c7gn.16xlarge, same AZ as server."
  type        = string
  default     = "c7gn.16xlarge"
}

variable "server_root_volume_gb" {
  type    = number
  default = 100
}

variable "client_root_volume_gb" {
  type    = number
  default = 50
}

variable "use_placement_group" {
  description = "Cluster placement group (lowest intra-AZ latency). Packing c7gn.12xlarge + c7gn.16xlarge onto the same rack often leaves the second instance pending with insufficient capacity; set false if apply stalls on aws_instance.server / client."
  type        = bool
  default     = true
}

variable "subnet_id" {
  description = "Optional: explicit subnet ID (must support the instance types and have a route to the internet for apt/git). If null, subnet is chosen from availability_zone (see below)."
  type        = string
  default     = null
}

variable "availability_zone" {
  description = "Used when subnet_id is null: pick the default-VPC subnet in this AZ. Large c7gn sizes are often out of stock in specific AZs (e.g. us-east-1c); AWS may direct you to 1a, 1b, 1d, or 1f. If null, defaults to the \"a\" AZ in the selected region (e.g. us-east-1a)."
  type        = string
  default     = null
}

variable "kividb_version" {
  description = "KiviDB release tag pre-fetched onto the server as a warm starting point (CI overwrites it with a from-source build)."
  type        = string
  default     = "v0.1.12"
}

variable "dragonfly_version" {
  description = "Dragonfly release tag pre-fetched onto the server."
  type        = string
  default     = "v1.37.0"
}

# ── GitHub Actions self-hosted runner (client instance only) ────────────────

variable "register_github_runner" {
  description = "If true, the client instance's startup script installs and self-registers a GitHub Actions self-hosted runner. Set to false for a plain client instance (e.g. manual/local use without CI)."
  type        = bool
  default     = false
}

variable "github_repository" {
  description = "GitHub \"owner/repo\" the runner registers against. Required when register_github_runner is true."
  type        = string
  default     = ""
}

variable "github_runner_registration_token" {
  description = "Short-lived registration token from POST /repos/{owner}/{repo}/actions/runners/registration-token. Required when register_github_runner is true. Not used for anything else, so it is safe to leave empty on destroy."
  type        = string
  default     = ""
  sensitive   = true
}

variable "github_runner_labels" {
  description = "Extra self-hosted runner labels, comma-separated, beyond the implicit \"self-hosted\" and \"run-<run_id>\" labels."
  type        = string
  default     = "benchmark,client"
}

variable "github_runner_version" {
  description = "actions/runner release to install on the client (arm64 tarball): a version such as \"2.337.0\", or \"latest\" for whichever is current when the instance boots. GitHub stops accepting registrations from old runners, so a pinned version goes stale."
  type        = string
  default     = "latest"

  validation {
    condition     = can(regex("^(latest|[0-9]+\\.[0-9]+\\.[0-9]+)$", var.github_runner_version))
    error_message = "github_runner_version must be \"latest\" or a version like 2.337.0."
  }
}
