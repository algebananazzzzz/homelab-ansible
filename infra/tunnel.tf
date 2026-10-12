locals {
  tunnel_name = var.project_code
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "ingress" {
  account_id = var.cloudflare_account_id
  name       = local.tunnel_name
  config_src = "local"
}

resource "cloudflare_dns_record" "wildcard" {
  zone_id = var.cloudflare_zone_id
  name    = "*.${var.cloudflare_zone}"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.ingress.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
}
