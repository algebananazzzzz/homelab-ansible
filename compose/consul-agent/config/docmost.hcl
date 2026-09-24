service {
  id   = "docmost"
  name = "docmost"
  port = 3000
  tags = [
    "traefik.enable=true",
    "traefik.http.routers.docmost.entrypoints=web,websecure",
    "traefik.http.routers.docmost.rule=Host(`docmost.svc.home.arpa`)",
    "traefik.http.routers.docmost.tls=true",
    "traefik.http.services.docmost.loadbalancer.server.port=3000"
  ]
  check {
    http     = "http://127.0.0.1:3000/"
    interval = "10s"
    timeout  = "5s"
  }
}
