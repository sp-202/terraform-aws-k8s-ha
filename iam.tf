# IAM Role for Nodes to modify their own Source/Dest Check
resource "aws_iam_role" "node_role" {
  name = "k8s-node-role"

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

resource "aws_iam_policy" "node_policy" {
  name        = "k8s-node-policy"
  description = "Allows k8s nodes to modify their own network interfaces (required for Cilium routing)"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "ec2:ModifyInstanceAttribute",
          "ec2:DescribeInstances",
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
  name = "k8s-node-profile"
  role = aws_iam_role.node_role.name
}
