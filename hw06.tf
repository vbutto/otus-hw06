# Роли сервисного аккаунта
# iam.serviceAccounts.admin - для создания сервисных аккаунтов
# container-registry.admin - для создания реестра и назначения прав


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
