service {
  id   = "mongo"
  name = "mongo"
  port = 27017
  check {
    tcp      = "127.0.0.1:27017"
    interval = "10s"
    timeout  = "2s"
  }
}
