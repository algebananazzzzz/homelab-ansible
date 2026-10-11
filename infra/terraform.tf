terraform {
  required_version = ">= 1.14"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # State key comes from config/lab.tfbackend:
  #   terraform init -backend-config=config/lab.tfbackend
  backend "s3" {}
}
