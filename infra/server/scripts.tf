# Read the bucket name from the storage folder's Terraform state.
data "terraform_remote_state" "storage" {
  backend = "local"

  config = {
    path = "${path.module}/../storage/terraform.tfstate"
  }
}

locals {
  bucket       = data.terraform_remote_state.storage.outputs.bucket_name
  instance_dir = "${path.module}/../../instance"
}

# Upload every file in instance/. The etag makes Terraform re-upload a file when it changes.
resource "aws_s3_object" "scripts" {
  for_each = fileset(local.instance_dir, "*")

  bucket = local.bucket
  key    = "scripts/${each.value}"
  source = "${local.instance_dir}/${each.value}"
  etag   = filemd5("${local.instance_dir}/${each.value}")
}

# Settings the server reads at boot.
resource "aws_s3_object" "config" {
  bucket  = local.bucket
  key     = "scripts/config.env"
  content = <<-EOT
    EULA=${var.accept_minecraft_eula}
    BUCKET=${local.bucket}
    VOLUME_ID=${aws_ebs_volume.data.id}
  EOT
}