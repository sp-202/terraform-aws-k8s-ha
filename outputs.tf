output "aws_region" {
  description = "AWS region"
  value       = var.aws_region
}

output "eks_cluster_name" {
  description = "EKS Cluster Name"
  value       = aws_eks_cluster.main.name
}

output "eks_cluster_endpoint" {
  description = "EKS API Server Endpoint"
  value       = aws_eks_cluster.main.endpoint
}

output "eks_cluster_ca" {
  description = "EKS Cluster CA Certificate (base64)"
  value       = aws_eks_cluster.main.certificate_authority[0].data
  sensitive   = true
}

output "eks_oidc_issuer" {
  description = "EKS OIDC Issuer URL (for IRSA)"
  value       = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

output "kubeconfig_command" {
  description = "Command to update kubeconfig for this cluster"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${var.cluster_name}"
}

output "pod_subnet_id" {
  description = "Pod subnet ID (passed to post-cluster-bootstrap.sh for Cilium ENI filter)"
  value       = aws_subnet.pods.id
}

output "worker_ips_command" {
  description = "List all running worker IPs"
  value       = "aws ec2 describe-instances --region ${var.aws_region} --filters \"Name=tag:Project,Values=${var.cluster_name}\" \"Name=instance-state-name,Values=running\" --query \"Reservations[*].Instances[*].[PrivateIpAddress,Tags[?Key=='Name'].Value|[0]]\" --output table"
}
