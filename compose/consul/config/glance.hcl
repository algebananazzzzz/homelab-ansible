service {
  id   = "glance"
  name = "glance"
  port = 8090
  tags = [
    "traefik.enable=true",
    "traefik.http.routers.glance.entrypoints=web",
    "traefik.http.routers.glance.rule=Host(`glance.home.arpa`)",
    "traefik.http.services.glance.loadbalancer.server.port=8090"
  ]
  check {
    http     = "http://127.0.0.1:8090/"
    interval = "10s"
    timeout  = "5s"
  }
}
