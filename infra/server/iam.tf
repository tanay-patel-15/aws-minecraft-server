# Lets EC2 instances use this role.
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "server" {
  name               = "minecraft-server"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

# AWS's managed policy for Session Manager, which replaces SSH.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.server.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Only this bucket: read scripts, read and write backups.
data "aws_iam_policy_document" "bucket" {
  statement {
    sid       = "ListBucket"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${local.bucket}"]
  }

  statement {
    sid       = "ReadScripts"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::${local.bucket}/scripts/*"]
  }

  statement {
    sid       = "ReadWriteBackups"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["arn:aws:s3:::${local.bucket}/backups/*"]
  }
}

resource "aws_iam_role_policy" "bucket" {
  name   = "minecraft-bucket"
  role   = aws_iam_role.server.id
  policy = data.aws_iam_policy_document.bucket.json
}

# The container that attaches a role to an EC2 instance.
resource "aws_iam_instance_profile" "server" {
  name = "minecraft-server"
  role = aws_iam_role.server.name
}