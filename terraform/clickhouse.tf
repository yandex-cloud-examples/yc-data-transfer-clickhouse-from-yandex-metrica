resource "yandex_mdb_clickhouse_cluster" "metrica" {
  name               = "ch-metrica-data"
  environment        = "PRODUCTION"
  network_id         = yandex_vpc_network.clickhouse-net.id
  security_group_ids = [yandex_vpc_default_security_group.clickhouse-sg.id]

  clickhouse {
    resources {
      resource_preset_id = "s3-c2-m8" # доступные конфигурации можно получить командой `yc managed-clickhouse resource-preset list`
      disk_type_id       = "network-ssd"
      disk_size          = 32
    }
  }

  host {
    type      = "CLICKHOUSE"
    zone      = "ru-central1-b"
    subnet_id = yandex_vpc_subnet.ch-subnet-b.id
    assign_public_ip = "true"
  }

  database {
    name = var.ch_db_name
  }

  user {
    name     = var.ch_user_name
    password = var.ch_user_password
    permission {
      database_name = var.ch_db_name
    }
  }

  access {
    web_sql = "true"
    data_lens = "true"
    data_transfer = "true"
    yandex_query = "true"
  }
}