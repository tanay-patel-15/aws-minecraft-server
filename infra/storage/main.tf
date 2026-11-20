resource "aws_s3_bucket" "world" {
  bucket_prefix = "minecraft-world-"
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "world" {
  bucket = aws_s3_bucket.world.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "world" {
  bucket = aws_s3_bucket.world.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "world" {
  bucket = aws_s3_bucket.world.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "world" {
  bucket = aws_s3_bucket.world.id

  # Lifecycle rules on a versioned bucket need versioning switched on first.
  depends_on = [aws_s3_bucket_versioning.world]

  rule {
    id     = "expire-old-backups"
    status = "Enabled"

    filter {
      prefix = "backups/"
    }


    # The current backup never expires. An older version is deleted 21 days after a
    # newer backup replaces it, but the 10 newest older versions are always kept.
    noncurrent_version_expiration {
      noncurrent_days           = 21
      newer_noncurrent_versions = 10
    }

    # Clean up uploads cut off mid-way, such as by a forced shutdown. Their parts are
    # invisible in the console but still stored.
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}