service {
  id   = "stirling"
  name = "stirling"
  port = 8080
  tags = [
    "traefik.enable=true",
    "traefik.http.routers.stirling.entrypoints=web",
    "traefik.http.routers.stirling.rule=Host(`stirling.home.arpa`)",
    "traefik.http.services.stirling.loadbalancer.server.port=8080"
  ]
  check {
    http     = "http://127.0.0.1:8080/"
    interval = "10s"
    timeout  = "5s"
  }
}
