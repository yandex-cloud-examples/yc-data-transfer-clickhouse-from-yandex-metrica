resource "yandex_vpc_default_security_group" "clickhouse-sg" {
  description = "Default security group"
  network_id = yandex_vpc_network.clickhouse-net.id

  ingress {
    description    = "HTTPS (secure)"
    port           = 8443
    protocol       = "TCP"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description    = "clickhouse-client (secure)"
    port           = 9440
    protocol       = "TCP"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "self"
    protocol = "ANY"
    predefined_target = "self_security_group"
  }

  egress {
    description    = "Allow all egress clickhouse traffic"
    protocol       = "TCP"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}