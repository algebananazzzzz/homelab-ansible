service {
  id   = "excalidraw"
  name = "excalidraw"
  port = 8083
  tags = [
    "traefik.enable=true",
    "traefik.http.routers.excalidraw.entrypoints=web",
    "traefik.http.routers.excalidraw.rule=Host(`excalidraw.home.arpa`)",
    "traefik.http.services.excalidraw.loadbalancer.server.port=8083"
  ]
  check {
    http     = "http://127.0.0.1:8083/"
    interval = "10s"
    timeout  = "5s"
  }
}
