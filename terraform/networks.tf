resource "yandex_vpc_network" "clickhouse-net" { 
  name = "clickhouse-net"
}

resource "yandex_vpc_subnet" "ch-subnet-a" {
  name           = "ch-subnet-ru-central1-a"
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.clickhouse-net.id
  v4_cidr_blocks = ["172.16.1.0/24"]
  route_table_id = yandex_vpc_route_table.rt.id
}

resource "yandex_vpc_subnet" "ch-subnet-b" {
  name           = "ch-subnet-ru-central1-b"
  zone           = "ru-central1-b"
  network_id     = yandex_vpc_network.clickhouse-net.id
  v4_cidr_blocks = ["172.16.2.0/24"]
  route_table_id = yandex_vpc_route_table.rt.id
}

resource "yandex_vpc_subnet" "ch-subnet-d" {
  name           = "ch-subnet-ru-central1-d"
  zone           = "ru-central1-d"
  network_id     = yandex_vpc_network.clickhouse-net.id
  v4_cidr_blocks = ["172.16.4.0/24"]
  route_table_id = yandex_vpc_route_table.rt.id
}

resource "yandex_vpc_gateway" "nat-gateway" {
  name = "clickhouse-nat-gateway"
  shared_egress_gateway {}
}

resource "yandex_vpc_route_table" "rt" {
  name       = "clickhouse-internet-outbound-route-table"
  network_id     = yandex_vpc_network.clickhouse-net.id
  static_route {
    destination_prefix = "0.0.0.0/0"
    gateway_id         = yandex_vpc_gateway.nat-gateway.id
  }
}