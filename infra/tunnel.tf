import {
  to = cloudflare_zero_trust_tunnel_cloudflared.homelab
  id = "5ca1b03dd7b0c9421ee9b410e5e9238d/9368815a-452c-4697-aff7-9d5940d6ee9a"
}

import {
  to = cloudflare_dns_record.tunnel
  id = "2e91baca813ae4743fbd69429bb4a4f4/80c9849bb2549d322ded4de5c54f496a"
}

# The tunnel secret stays in .env, where Ansible builds cloudflared's credentials from it.
resource "cloudflare_zero_trust_tunnel_cloudflared" "homelab" {
  account_id = "5ca1b03dd7b0c9421ee9b410e5e9238d"
  name       = "homelab"
  config_src = "local"
}

resource "cloudflare_dns_record" "tunnel" {
  zone_id = "2e91baca813ae4743fbd69429bb4a4f4"
  name    = "*.algebananazzzzz.com"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
}
