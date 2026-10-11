output "backup_bucket" {
  description = "Must match backup_bucket in roles/backup/vars/main.yml."
  value       = aws_s3_bucket.backup.bucket
}

output "backup_user" {
  description = "Create its access key with the sops pipe on the Disaster Recovery page."
  value       = aws_iam_user.backup.name
}
