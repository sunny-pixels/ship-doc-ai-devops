output "bucket_name" {
  description = "Backup bucket name (S3_BUCKET for backup.sh)."
  value       = aws_s3_bucket.backups.bucket
}

output "s3_endpoint" {
  description = "Endpoint backup.sh passes to the AWS CLI."
  value       = var.localstack_endpoint
}

output "backup_access_key_id" {
  description = "Access key id of the ultradoc-backup IAM user."
  value       = aws_iam_access_key.backup.id
}

output "backup_secret_access_key" {
  description = "Secret key of the ultradoc-backup IAM user. Read with: terraform output -raw backup_secret_access_key"
  value       = aws_iam_access_key.backup.secret
  sensitive   = true
}
