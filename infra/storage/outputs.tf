output "bucket_name" {
  description = "S3 bucket that stores world backups and instance scripts"
  value       = aws_s3_bucket.world.bucket
}