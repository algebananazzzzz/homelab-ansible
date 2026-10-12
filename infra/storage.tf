locals {
  backup_bucket_name = "${var.env}-com-s3-${var.project_code}-backup"
}

resource "aws_s3_bucket" "restic" {
  bucket = local.backup_bucket_name
}

resource "aws_s3_bucket_public_access_block" "restic" {
  bucket = aws_s3_bucket.restic.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "restic" {
  bucket = aws_s3_bucket.restic.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "restic" {
  bucket     = aws_s3_bucket.restic.id
  depends_on = [aws_s3_bucket_versioning.restic]

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
