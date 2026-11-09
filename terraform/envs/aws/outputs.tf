output "backup_bucket" {
  description = "Offsite backup bucket name."
  value       = aws_s3_bucket.backups.bucket
}
