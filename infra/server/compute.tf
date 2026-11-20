# The latest Amazon Linux 2023 image, looked up from AWS's public parameter.
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_instance" "minecraft" {
  ami                                  = data.aws_ssm_parameter.al2023.value
  instance_type                        = var.instance_type
  subnet_id                            = aws_subnet.public.id
  vpc_security_group_ids               = [aws_security_group.minecraft.id]
  iam_instance_profile                 = aws_iam_instance_profile.server.name
  instance_initiated_shutdown_behavior = "stop"

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    bucket = local.bucket
  })

  # IMDSv2: requires a session token to read instance metadata.
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_type = "gp3"
    encrypted   = true
  }

  # The scripts must be in S3 before the first boot reads them.
  depends_on = [aws_s3_object.scripts, aws_s3_object.config]

  # Never replace the server because a newer image came out or user_data changed.
  lifecycle {
    ignore_changes = [ami, user_data]
  }

  tags = {
    Name = "minecraft"
  }
}

# The world disk. It is separate from the instance, so replacing the server keeps the world.
resource "aws_ebs_volume" "data" {
  availability_zone = aws_subnet.public.availability_zone
  size              = 10
  type              = "gp3"
  encrypted         = true

  tags = {
    Name = "minecraft-world"
  }
}

resource "aws_volume_attachment" "data" {
  device_name                    = "/dev/sdf"
  volume_id                      = aws_ebs_volume.data.id
  instance_id                    = aws_instance.minecraft.id
  stop_instance_before_detaching = true
}

resource "aws_eip_association" "minecraft" {
  instance_id   = aws_instance.minecraft.id
  allocation_id = aws_eip.minecraft.id
}