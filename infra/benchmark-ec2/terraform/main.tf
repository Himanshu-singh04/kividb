provider "aws" {
  region = var.aws_region
}

data "aws_vpc" "default" {
  default = true
}

locals {
  # Avoid nondeterministic default-VPC subnet order (e.g. us-east-1c) where c7gn.12xlarge may have no capacity.
  effective_az = coalesce(var.availability_zone, "${var.aws_region}a")
}

data "aws_subnets" "in_effective_az" {
  count = var.subnet_id == null ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "availability-zone"
    values = [local.effective_az]
  }
}

locals {
  subnet_id = var.subnet_id != null ? var.subnet_id : data.aws_subnets.in_effective_az[0].ids[0]
}

data "aws_subnet" "selected" {
  id = local.subnet_id
}

# Cluster placement groups are bound to a single AZ. Include run_id so a cancelled apply
# cannot leave a region-wide name (`…-cluster-useast1a`) that blocks the next run, and so
# teardown can find the group by tag when Terraform never exported IDs.
locals {
  resource_suffix             = "${var.project_name}-${var.run_id}"
  placement_group_name_suffix = replace(data.aws_subnet.selected.availability_zone, "-", "")
  common_tags = {
    Project = var.project_name
    RunId   = var.run_id
  }
}

data "aws_ami" "ubuntu_jammy_arm64" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-arm64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}

# Key pair is generated for this run from a caller-supplied public key rather than requiring a
# pre-existing AWS key pair, so the module needs no manual one-time setup in a new AWS account.
resource "aws_key_pair" "benchmark" {
  key_name_prefix = "${local.resource_suffix}-"
  public_key      = var.ssh_public_key
  tags            = local.common_tags
}

resource "aws_placement_group" "benchmark" {
  count    = var.use_placement_group ? 1 : 0
  name     = "${local.resource_suffix}-cluster-${local.placement_group_name_suffix}"
  strategy = "cluster"
  tags     = local.common_tags
}

resource "aws_security_group" "benchmark" {
  name_prefix = "${local.resource_suffix}-"
  description = "SSH + Redis ports for benchmark client/server"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_cidr]
  }

  ingress {
    description = "Redis / Kivi between benchmark hosts"
    from_port   = 6379
    to_port     = 6380
    protocol    = "tcp"
    self        = true
  }

  ingress {
    description = "ICMP ping (runbook latency check)"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.common_tags, {
    Name = "${local.resource_suffix}-sg"
  })
}

resource "aws_instance" "server" {
  ami                    = data.aws_ami.ubuntu_jammy_arm64.id
  instance_type          = var.server_instance_type
  key_name               = aws_key_pair.benchmark.key_name
  subnet_id              = local.subnet_id
  vpc_security_group_ids = [aws_security_group.benchmark.id]

  placement_group = var.use_placement_group ? aws_placement_group.benchmark[0].name : null

  user_data = base64encode(templatefile("${path.module}/user_data/server.sh.tftpl", {
    kividb_version    = var.kividb_version
    dragonfly_version = var.dragonfly_version
  }))

  root_block_device {
    volume_size           = var.server_root_volume_gb
    volume_type           = "gp3"
    delete_on_termination = true
  }

  # Pending for a few minutes is normal for large c7gn. Waiting 60m hides
  # insufficient-capacity / cluster-placement-group failure as a "hang".
  timeouts {
    create = "20m"
    delete = "30m"
  }

  tags = merge(local.common_tags, {
    Name = "${local.resource_suffix}-server"
    Role = "redis-dragonfly-kividb-server"
  })
}

resource "aws_instance" "client" {
  ami                    = data.aws_ami.ubuntu_jammy_arm64.id
  instance_type          = var.client_instance_type
  key_name               = aws_key_pair.benchmark.key_name
  subnet_id              = local.subnet_id
  vpc_security_group_ids = [aws_security_group.benchmark.id]

  placement_group = var.use_placement_group ? aws_placement_group.benchmark[0].name : null

  user_data = base64encode(templatefile("${path.module}/user_data/client.sh.tftpl", {
    register_github_runner = var.register_github_runner
    github_repository      = var.github_repository
    registration_token     = var.github_runner_registration_token
    runner_name            = "${local.resource_suffix}-client"
    runner_labels          = "self-hosted,run-${var.run_id},${var.github_runner_labels}"
    runner_version         = var.github_runner_version
  }))

  root_block_device {
    volume_size           = var.client_root_volume_gb
    volume_type           = "gp3"
    delete_on_termination = true
  }

  timeouts {
    create = "20m"
    delete = "30m"
  }

  # Launch the 12xlarge into an empty cluster PG first. Creating both in parallel lets the
  # 16xlarge client win the rack, after which the server sits in pending until the 20m timeout.
  depends_on = [aws_instance.server]

  tags = merge(local.common_tags, {
    Name = "${local.resource_suffix}-client"
    Role = "memtier-client"
  })
}
