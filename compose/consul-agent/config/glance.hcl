service {
  id   = "glance"
  name = "glance"
  port = 8090
  tags = [
    "traefik.enable=true",
    "traefik.http.routers.glance.entrypoints=web,websecure",
    "traefik.http.routers.glance.rule=Host(`home.arpa`)",
    "traefik.http.routers.glance.tls=true",
    "traefik.http.services.glance.loadbalancer.server.port=8090"
  ]
  check {
    http     = "http://127.0.0.1:8090/"
    interval = "10s"
    timeout  = "5s"
  }
}
