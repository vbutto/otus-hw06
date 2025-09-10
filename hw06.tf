# Роли сервисного аккаунта
# iam.serviceAccounts.admin - для создания сервисных аккаунтов
# container-registry.admin - для создания реестра и назначения прав
# serverless.containers.admin - для создания функций
# vpc.publicAdmin - для создания VPC-сети и подсети
# vpc.privateAdmin - для создания VPC-сети и подсети
# compute.admin - для создания группы ВМ



locals {
  # Достаём id сервисного аккаунта из JSON-ключа, который уже используете в providers.tf
  sa_id = jsondecode(file(var.sa_key_file)).service_account_id
}

resource "yandex_container_registry" "cr" {
  name      = "cr-demo"
  folder_id = var.folder_id
  labels    = { env = "hw" }
}



resource "yandex_iam_service_account" "sa_ci" {
  name = "sa-ci"
}

resource "yandex_container_registry_iam_binding" "pusher" {
  registry_id = yandex_container_registry.cr.id
  role        = "container-registry.images.pusher"
  members     = ["serviceAccount:${yandex_iam_service_account.sa_ci.id}"]
}

# создаем serverless container

resource "yandex_iam_service_account" "sa_sls" { name = "sa-sls" }

resource "yandex_container_registry_iam_binding" "sls_puller" {
  registry_id = yandex_container_registry.cr.id
  role        = "container-registry.images.puller"
  members     = ["serviceAccount:${yandex_iam_service_account.sa_sls.id}"]
}

resource "yandex_resourcemanager_folder_iam_member" "sa_sls_invoker" {
  folder_id = var.folder_id
  role      = "serverless.containers.invoker"
  member    = "serviceAccount:${yandex_iam_service_account.sa_sls.id}"
}

resource "yandex_serverless_container" "app" {
  name               = "sls-demo"
  description        = "Serverless container demo"
  service_account_id = yandex_iam_service_account.sa_sls.id
  memory             = 256 # MiB
  cores              = 1

  image {
    url = "cr.yandex/${yandex_container_registry.cr.id}/node-hello:1.0"
  }
  concurrency       = 8
  execution_timeout = "30s"

  # Для VPC-доступа можно добавить connectivity { network_id, subnet_ids }

  depends_on = [yandex_container_registry_iam_binding.sls_puller]
}

# создаем контейнер в Container Solution

# ---- сеть ----
resource "yandex_vpc_network" "net" {
  name = "net-demo"
}



resource "yandex_vpc_subnet" "sn_a" {
  name           = "sn-a"
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.net.id
  v4_cidr_blocks = ["10.10.0.0/24"]
}


# ---- SA для IG (он будет тянуть образы) ----
resource "yandex_iam_service_account" "sa_ci_ig" {
  name = "sa-ci-ig"
}

# Разрешаем этому SA тянуть образы из CR
resource "yandex_container_registry_iam_binding" "ig_puller" {
  registry_id = yandex_container_registry.cr.id
  role        = "container-registry.images.puller"
  members     = ["serviceAccount:${yandex_iam_service_account.sa_ci_ig.id}"]
}

resource "yandex_resourcemanager_folder_iam_member" "sa_ci_ig_editor" {
  folder_id = var.folder_id
  role      = "editor" # можно "editor" если не хочешь размазывать роли
  member    = "serviceAccount:${yandex_iam_service_account.sa_ci_ig.id}"
}

resource "yandex_resourcemanager_folder_iam_member" "sa_ci_ig_vpc_user" {
  folder_id = var.folder_id
  role      = "vpc.user"
  member    = "serviceAccount:${yandex_iam_service_account.sa_ci_ig.id}"
}

resource "yandex_resourcemanager_folder_iam_member" "sa_ci_ig_compute_editor" {
  folder_id = var.folder_id
  role      = "compute.editor" # можно compute.admin, но editor обычно достаточно
  member    = "serviceAccount:${yandex_iam_service_account.sa_ci_ig.id}"
}

resource "yandex_resourcemanager_folder_iam_member" "sa_ci_ig_lb_editor" {
  folder_id = var.folder_id
  role      = "load-balancer.editor" # можно .admin, но editor обычно достаточно
  member    = "serviceAccount:${yandex_iam_service_account.sa_ci_ig.id}"
}


# ---- контейнер-оптимизированный образ ----
data "yandex_compute_image" "coi" {
  family = "container-optimized-image"
}

# ---- группа ВМ с декларацией контейнера ----
resource "yandex_compute_instance_group" "ig" {
  name               = "cs-demo"
  service_account_id = yandex_iam_service_account.sa_ci_ig.id

  allocation_policy { zones = ["ru-central1-a"] }

  deploy_policy {
    max_unavailable = 1
    max_expansion   = 0
    max_creating    = 1
    max_deleting    = 1
    strategy        = "proactive" # по умолчанию; можно опустить
  }

  instance_template {
    platform_id = "standard-v3"
    resources {
      cores  = 2
      memory = 2
    }

    boot_disk {
      initialize_params {
        image_id = data.yandex_compute_image.coi.id
        size     = 20
        type     = "network-ssd"
      }
    }

    network_interface {
      subnet_ids = [yandex_vpc_subnet.sn_a.id]
      nat        = true
    }

    # Декларация контейнера — JSON строкой
    metadata = {
      "docker-container-declaration" = jsonencode({
        spec = {
          containers = [{
            name  = "app"
            image = "cr.yandex/${yandex_container_registry.cr.id}/node-hello:1.0"
            # если нужно — command/args/env
            ports = [{ name = "http", containerPort = 8080 }]
            env   = [{ name = "PORT", value = "8080" }]
          }]
          restartPolicy = "Always"
        }
      })
    }
  }

  # Минимальный масштаб
  scale_policy {
    fixed_scale { size = 1 }
  }

  # Target group для NLB
  load_balancer {
    target_group_name = "tg-cs-demo"
  }

  # Здоровье контейнера
  health_check {
    http_options {
      port = 8080
      path = "/"
    }
    interval            = 2
    timeout             = 1
    unhealthy_threshold = 5
    healthy_threshold   = 2
  }

  depends_on = [
    yandex_resourcemanager_folder_iam_member.sa_ci_ig_editor,
    yandex_container_registry_iam_binding.ig_puller,
    yandex_resourcemanager_folder_iam_member.sa_ci_ig_vpc_user,
    yandex_resourcemanager_folder_iam_member.sa_ci_ig_compute_editor,
    yandex_resourcemanager_folder_iam_member.sa_ci_ig_lb_editor,
  ]
}

# ---- Публичный L4 балансировщик ----
resource "yandex_lb_network_load_balancer" "nlb" {
  name = "nlb-cs-demo"

  listener {
    name = "http-80"
    port = 80
    external_address_spec { ip_version = "ipv4" }
  }

  attached_target_group {
    target_group_id = yandex_compute_instance_group.ig.load_balancer[0].target_group_id
    healthcheck {
      name = "hc"
      http_options {
        port = 8080
        path = "/"
      }
      interval            = 2
      timeout             = 1
      unhealthy_threshold = 5
      healthy_threshold   = 2
    }
  }
}

output "nlb_external_ips" {
  value = flatten([
    for l in yandex_lb_network_load_balancer.nlb.listener :
    [for ea in l.external_address_spec : ea.address]
  ])
}

