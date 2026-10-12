variable "env" {
  description = "Environment this apply targets. First segment of every resource name."
  type        = string

  validation {
    condition     = contains(["lab"], var.env)
    error_message = "env is not one of the environments this project defines."
  }
}

variable "project_code" {
  description = "Project code. Fourth segment of every resource name."
  type        = string
}

variable "aws_region" {
  description = "Region of the backup bucket. restic's repository URL in roles/backup/vars/main.yml names it too."
  type        = string
}

variable "cloudflare_account_id" {
  description = "Account that owns the tunnel."
  type        = string
}

variable "cloudflare_zone_id" {
  description = "Zone that holds the tunnel's wildcard record."
  type        = string
}

variable "cloudflare_zone" {
  description = "Domain of that zone. Every hostname under it routes through the tunnel."
  type        = string
}
