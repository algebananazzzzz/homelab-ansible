resource "aws_s3_bucket" "backup" {
  bucket = "lab-com-s3-homelab-backup"
}

resource "aws_s3_bucket_public_access_block" "backup" {
  bucket = aws_s3_bucket.backup.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "backup" {
  bucket = aws_s3_bucket.backup.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backup" {
  bucket     = aws_s3_bucket.backup.id
  depends_on = [aws_s3_bucket_versioning.backup]

  rule {
    id     = "expire-deleted-after-30-days"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    expiration {
      expired_object_delete_marker = true
    }
  }
}

# The key is created outside Terraform, straight into sops, so its secret never lands in state.
resource "aws_iam_user" "backup" {
  name = "lab-com-iamuser-homelab-backup"
}

resource "aws_iam_user_policy" "backup_assume_role" {
  name = "lab-com-iampolicy-homelab-backup-assumerole"
  user = aws_iam_user.backup.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = module.backup_role.role.arn
    }]
  })
}

module "backup_role" {
  source = "github.com/algebananazzzzz/terraform-modules//iam_role?ref=v0.0.2"

  name = "lab-com-iamrole-homelab-backup"
  assume_role_allowed_principals = [{
    type        = "AWS"
    identifiers = [aws_iam_user.backup.arn]
  }]
  custom_policy = {
    name        = "lab-com-iampolicy-homelab-backup"
    description = "Lets the homelab hosts run restic against the backup bucket."
    statements = {
      ListBucket = {
        effect    = "Allow"
        actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
        resources = [aws_s3_bucket.backup.arn]
      }
      ReadWriteObjects = {
        effect    = "Allow"
        actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        resources = ["${aws_s3_bucket.backup.arn}/*"]
      }
    }
  }
}
