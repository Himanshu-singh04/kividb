output "server_instance_id" {
  value = aws_instance.server.id
}

output "client_instance_id" {
  value = aws_instance.client.id
}

output "server_private_ip" {
  description = "memtier -s target (Dragonfly README: SERVER_PRIVATE_IP)."
  value       = aws_instance.server.private_ip
}

output "server_public_ip" {
  description = "SSH if the subnet assigns a public address."
  value       = aws_instance.server.public_ip
}

output "client_private_ip" {
  value = aws_instance.client.private_ip
}

output "client_public_ip" {
  value = aws_instance.client.public_ip
}

output "ssh_user" {
  value = "ubuntu"
}

output "key_pair_name" {
  description = "Needed to delete the key pair on teardown."
  value       = aws_key_pair.benchmark.key_name
}

output "security_group_id" {
  description = "Needed to delete the security group on teardown (after both instances terminate)."
  value       = aws_security_group.benchmark.id
}

output "placement_group_name" {
  description = "Empty string when use_placement_group is false."
  value       = var.use_placement_group ? aws_placement_group.benchmark[0].name : ""
}

output "region" {
  value = var.aws_region
}

output "subnet_id" {
  description = "Subnet used by both instances (for debugging capacity / AZ issues)."
  value       = local.subnet_id
}

output "availability_zone" {
  description = "AZ for the subnet above."
  value       = data.aws_subnet.selected.availability_zone
}

output "run_id" {
  value = var.run_id
}
