service {
  id   = "beaverhabits"
  name = "beaverhabits"
  port = 8082
  tags = [
    "traefik.enable=true",
    "traefik.http.routers.beaverhabits.entrypoints=web,websecure",
    "traefik.http.routers.beaverhabits.rule=Host(`beaverhabits.svc.home.arpa`)",
    "traefik.http.routers.beaverhabits.tls=true",
    "traefik.http.services.beaverhabits.loadbalancer.server.port=8082"
  ]
  check {
    http     = "http://127.0.0.1:8082/"
    interval = "10s"
    timeout  = "5s"
  }
}
