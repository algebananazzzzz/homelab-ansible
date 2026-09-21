service {
  id   = "beaverhabits"
  name = "beaverhabits"
  port = 8082
  tags = [
    "traefik.enable=true",
    "traefik.http.routers.beaverhabits.entrypoints=web",
    "traefik.http.routers.beaverhabits.rule=Host(`beaverhabits.home.arpa`)",
    "traefik.http.services.beaverhabits.loadbalancer.server.port=8082"
  ]
  check {
    http     = "http://127.0.0.1:8082/"
    interval = "10s"
    timeout  = "5s"
  }
}
