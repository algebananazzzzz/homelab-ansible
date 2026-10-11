# Off-site restic repository for the homelab backups. See the Disaster Recovery page in Outline.
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

# A host holding the backup key can delete objects, because restic prunes; versioning keeps them recoverable for 30 days.
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

# The access key is created outside Terraform, straight into sops, so its secret never lands in state.
resource "aws_iam_user" "backup" {
  name = "lab-com-iamuser-homelab-backup"
}

module "backup_policy" {
  source = "github.com/algebananazzzzz/terraform-modules//iam_policy?ref=v0.0.3"

  name        = "lab-com-iampolicy-homelab-backup"
  description = "Lets the homelab hosts run restic against the backup bucket."
  document_statements = {
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

resource "aws_iam_user_policy_attachment" "backup" {
  user       = aws_iam_user.backup.name
  policy_arn = module.backup_policy.arn
}
