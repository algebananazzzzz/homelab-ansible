service {
  id   = "docmost"
  name = "docmost"
  port = 3000
  tags = [
    "traefik.enable=true",
    "traefik.http.routers.docmost.entrypoints=web",
    "traefik.http.routers.docmost.rule=Host(`docmost.home.arpa`)",
    "traefik.http.services.docmost.loadbalancer.server.port=3000"
  ]
  check {
    http     = "http://127.0.0.1:3000/"
    interval = "10s"
    timeout  = "5s"
  }
}
