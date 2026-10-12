locals {
  backup_user_name        = "${var.env}-com-iamuser-${var.project_code}-backup"
  backup_user_policy_name = "${var.env}-com-iampolicy-${var.project_code}-backup-assumerole"
  backup_role_name        = "${var.env}-com-iamrole-${var.project_code}-backup"
  backup_role_policy_name = "${var.env}-com-iampolicy-${var.project_code}-backup"
}

# The key is created outside Terraform, straight into .env, so its secret never lands in state.
resource "aws_iam_user" "restic" {
  name = local.backup_user_name
}

resource "aws_iam_user_policy" "restic_assume_role" {
  name = local.backup_user_policy_name
  user = aws_iam_user.restic.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = module.restic_role.role.arn
    }]
  })
}

module "restic_role" {
  source = "github.com/algebananazzzzz/terraform-modules//iam_role?ref=v0.0.2"

  name = local.backup_role_name
  assume_role_allowed_principals = [{
    type        = "AWS"
    identifiers = [aws_iam_user.restic.arn]
  }]
  custom_policy = {
    name        = local.backup_role_policy_name
    description = "Lets the backup hosts run restic against the backup bucket."
    statements = {
      ListBucket = {
        effect    = "Allow"
        actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
        resources = [aws_s3_bucket.restic.arn]
      }
      ReadWriteObjects = {
        effect    = "Allow"
        actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        resources = ["${aws_s3_bucket.restic.arn}/*"]
      }
    }
  }
}
