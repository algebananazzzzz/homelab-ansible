service {
  id   = "prometheus"
  name = "prometheus"
  port = 9090
  tags = [
    "traefik.enable=true",
    "traefik.http.routers.prometheus.entrypoints=web",
    "traefik.http.routers.prometheus.rule=Host(`prometheus.home.arpa`)",
    "traefik.http.services.prometheus.loadbalancer.server.port=9090"
  ]
  check {
    http     = "http://127.0.0.1:9090/-/healthy"
    interval = "10s"
    timeout  = "5s"
  }
}
