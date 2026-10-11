provider "aws" {
  region = "ap-southeast-1"

  default_tags {
    tags = {
      Environment = "lab"
      Project     = "homelab"
      ManagedBy   = "terraform"
    }
  }
}

provider "cloudflare" {}
