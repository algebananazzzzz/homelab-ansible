output "backup_bucket" {
  description = "Must match backup_bucket in roles/backup/vars/main.yml."
  value       = aws_s3_bucket.backup.bucket
}

output "backup_user" {
  description = "Its access key goes into .env as BACKUP_AWS_ACCESS_KEY_ID and BACKUP_AWS_SECRET_ACCESS_KEY."
  value       = aws_iam_user.backup.name
}

output "backup_role_arn" {
  description = "Goes into .env as RESTIC_AWS_ASSUME_ROLE_ARN;restic assumes it with the user's key."
  value       = module.backup_role.role.arn
}
