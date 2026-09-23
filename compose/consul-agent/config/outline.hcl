service {
  id   = "outline"
  name = "outline"
  port = 3001
  tags = [
    "traefik.enable=true",
    "traefik.http.routers.outline.entrypoints=web,websecure",
    "traefik.http.routers.outline.rule=Host(`outline.algebananazzzzz.com`)",
    "traefik.http.routers.outline.tls=true",
    "traefik.http.services.outline.loadbalancer.server.port=3001"
  ]
  check {
    http     = "http://127.0.0.1:3001/_health"
    interval = "10s"
    timeout  = "5s"
  }
}
