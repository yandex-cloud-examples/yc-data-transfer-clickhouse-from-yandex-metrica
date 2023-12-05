resource "yandex_datatransfer_endpoint" "ch-target" {
  name = "clickhouse-metrica"
  settings {
    clickhouse_target {
        connection {
            connection_options {
              mdb_cluster_id = yandex_mdb_clickhouse_cluster.metrica.id
              database = var.ch_db_name
              user = var.ch_user_name
              password {
                raw = var.ch_user_password
              }
            }
        }
        cleanup_policy = "CLICKHOUSE_CLEANUP_POLICY_DISABLED"
        security_groups = [yandex_vpc_default_security_group.clickhouse-sg.id]
        subnet_id = yandex_vpc_subnet.ch-subnet-d.id
    }
  }
}