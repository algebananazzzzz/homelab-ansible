service {
  id   = "postgres"
  name = "postgres"
  port = 5432
  check {
    tcp      = "127.0.0.1:5432"
    interval = "10s"
    timeout  = "2s"
  }
}
