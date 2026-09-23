service {
  id   = "prometheus"
  name = "prometheus"
  port = 9090
  tags = [
    "traefik.enable=true",
    "traefik.http.routers.prometheus.entrypoints=web,websecure",
    "traefik.http.routers.prometheus.rule=Host(`prometheus.ops.home.arpa`)",
    "traefik.http.routers.prometheus.tls=true",
    "traefik.http.services.prometheus.loadbalancer.server.port=9090"
  ]
  check {
    http     = "http://127.0.0.1:9090/-/healthy"
    interval = "10s"
    timeout  = "5s"
  }
}
