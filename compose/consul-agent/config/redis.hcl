service {
  id   = "redis"
  name = "redis"
  port = 6379
  check {
    tcp      = "127.0.0.1:6379"
    interval = "10s"
    timeout  = "2s"
  }
}
