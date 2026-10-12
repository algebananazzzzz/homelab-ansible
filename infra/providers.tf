provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = var.env
      Project     = var.project_code
      ManagedBy   = "terraform"
    }
  }
}

provider "cloudflare" {}
