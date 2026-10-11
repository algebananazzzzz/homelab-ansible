output "backup_bucket" {
  description = "Must match backup_bucket in roles/backup/vars/main.yml."
  value       = aws_s3_bucket.backup.bucket
}

output "backup_user" {
  description = "Create its access key with the sops pipe on the Disaster Recovery page."
  value       = aws_iam_user.backup.name
}

output "backup_role_arn" {
  description = "Goes into sops as backup_secrets.role_arn; restic assumes it with the user's key."
  value       = module.backup_role.role.arn
}
