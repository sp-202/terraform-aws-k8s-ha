output "master_public_ip" {
  description = "Public IP of the Master Node"
  value       = aws_instance.master.public_ip
}

output "master_private_ip" {
  description = "Private IP of the Master Node"
  value       = aws_instance.master.private_ip
}

output "k3s_token" {
  description = "K3s Cluster Token"
  value       = random_password.k3s_token.result
  sensitive   = true
}

output "ssh_command" {
  description = "Command to SSH into Master"
  value       = "ssh ubuntu@${aws_instance.master.public_ip}"
}

output "worker_ips_command" {
  description = "Since workers are managed by ASG, their IPs are dynamic. Use this command to list them:"
  value       = "aws ec2 describe-instances --filters \"Name=tag:aws:autoscaling:groupName,Values=${aws_autoscaling_group.workers.name}\" \"Name=instance-state-name,Values=running\" --query \"Reservations[*].Instances[*].PrivateIpAddress\" --output text"
}
