service {
  id   = "kaneo"
  name = "kaneo"
  port = 5173
  tags = [
    "traefik.enable=true",
    "traefik.http.routers.kaneo.entrypoints=web,websecure",
    "traefik.http.routers.kaneo.rule=Host(`kaneo.algebananazzzzz.com`)",
    "traefik.http.routers.kaneo.tls=true",
    "traefik.http.services.kaneo.loadbalancer.server.port=5173"
  ]
  check {
    http     = "http://127.0.0.1:5173/"
    interval = "10s"
    timeout  = "5s"
  }
}
