# -------------------------------------------------------
# IAM for EKS self-managed worker nodes
# -------------------------------------------------------

resource "aws_iam_role" "node_role" {
  name = "${var.cluster_name}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

# Required for EKS self-managed nodes to register with the control plane
resource "aws_iam_role_policy_attachment" "node_eks_worker" {
  role       = aws_iam_role.node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

# Required for kubelet to pull images from ECR
resource "aws_iam_role_policy_attachment" "node_ecr_readonly" {
  role       = aws_iam_role.node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# Required for VPC CNI (and Cilium ENI mode) to manage ENIs
resource "aws_iam_role_policy_attachment" "node_eks_cni" {
  role       = aws_iam_role.node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

# Custom policy for Cilium ENI mode + instance self-management
resource "aws_iam_policy" "node_policy" {
  name        = "${var.cluster_name}-node-policy"
  description = "Allows k8s nodes to manage ENIs for Cilium AWS ENI mode"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "ec2:ModifyInstanceAttribute",
          "ec2:DescribeInstances",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeSubnets",
          "ec2:DescribeVpcs",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeRouteTables",
          "ec2:CreateNetworkInterface",
          "ec2:AttachNetworkInterface",
          "ec2:DetachNetworkInterface",
          "ec2:DeleteNetworkInterface",
          "ec2:ModifyNetworkInterfaceAttribute",
          "ec2:AssignPrivateIpAddresses",
          "ec2:UnassignPrivateIpAddresses",
          "ec2:CreateTags",
          "ec2:DescribeTags",
          "ec2:TerminateInstances"
        ]
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "node_attach" {
  role       = aws_iam_role.node_role.name
  policy_arn = aws_iam_policy.node_policy.arn
}

resource "aws_iam_instance_profile" "node_profile" {
  name = "${var.cluster_name}-node-profile"
  role = aws_iam_role.node_role.name
}

# Allow this node role to authenticate with EKS
# (equivalent of adding the role to aws-auth ConfigMap)
resource "aws_iam_role_policy" "node_eks_auth" {
  name = "${var.cluster_name}-node-eks-auth"
  role = aws_iam_role.node_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = "eks:DescribeCluster"
        Effect   = "Allow"
        Resource = aws_eks_cluster.main.arn
      }
    ]
  })
}
