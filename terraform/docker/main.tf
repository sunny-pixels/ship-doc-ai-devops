locals {
  repo_root       = abspath("${path.module}/../..")
  nginx_conf_path = coalesce(var.nginx_conf_path, "${local.repo_root}/nginx/default.conf")
  cert_dir        = coalesce(var.cert_dir, "${local.repo_root}/nginx/certs")

  # Rotate container logs so a chatty container can't fill the disk.
  log_opts = {
    max-size = "10m"
    max-file = "3"
  }
}

# ---- Network + storage ----

resource "docker_network" "app" {
  name = "${var.name_prefix}_net"
}

# Uploads + Chroma store. Named so backup.sh / restore.sh can find it.
# `terraform destroy` deletes it too: run scripts/backup.sh first.
resource "docker_volume" "data" {
  name = "${var.name_prefix}_data"
}

# ---- Images ----
# api/web are built on the host (docker build -t ultradoc-api:<tag>) and only
# looked up here; nginx is pulled from Docker Hub.

data "docker_image" "api" {
  name = "${var.name_prefix}-api:${var.image_tag}"
}

data "docker_image" "web" {
  name = "${var.name_prefix}-web:${var.image_tag}"
}

resource "docker_image" "nginx" {
  name         = var.nginx_image
  keep_locally = true
}

# ---- Containers ----

resource "docker_container" "api" {
  name    = "${var.name_prefix}-api"
  image   = data.docker_image.api.id
  restart = "unless-stopped"

  env = [
    "ENV=production",
    "LLM_API_KEY=${var.llm_api_key}",
    "LLM_BASE_URL=${var.llm_base_url}",
    "LLM_MODEL=${var.llm_model}",
    "MAX_UPLOAD_MB=${var.max_upload_mb}",
    "DATA_DIR=/app/data",
    "MODEL_CACHE_DIR=/app/models",
    "LOG_LEVEL=${var.log_level}",
    "LOG_FORMAT=json",
  ]

  networks_advanced {
    name    = docker_network.app.id
    aliases = ["api"]
  }

  volumes {
    volume_name    = docker_volume.data.name
    container_path = "/app/data"
  }

  log_driver = "json-file"
  log_opts   = local.log_opts

  # Block until the image's HEALTHCHECK passes, so nginx starts after it.
  wait         = true
  wait_timeout = 120
}

resource "docker_container" "web" {
  name    = "${var.name_prefix}-web"
  image   = data.docker_image.web.id
  restart = "unless-stopped"

  env = [
    "API_INTERNAL_URL=http://api:8000/",
  ]

  networks_advanced {
    name    = docker_network.app.id
    aliases = ["web"]
  }

  log_driver = "json-file"
  log_opts   = local.log_opts

  wait         = true
  wait_timeout = 120

  depends_on = [docker_container.api]
}

resource "docker_container" "nginx" {
  name    = "${var.name_prefix}-nginx"
  image   = docker_image.nginx.image_id
  restart = "unless-stopped"

  ports {
    internal = 80
    external = var.http_port
  }

  ports {
    internal = 443
    external = var.https_port
  }

  networks_advanced {
    name = docker_network.app.id
  }

  # Config and certs are copied in rather than bind-mounted, so this works
  # the same wherever Terraform runs. Changing either file replaces nginx.
  upload {
    file    = "/etc/nginx/conf.d/default.conf"
    content = file(local.nginx_conf_path)
  }

  upload {
    file    = "/etc/nginx/certs/selfsigned.crt"
    content = file("${local.cert_dir}/selfsigned.crt")
  }

  upload {
    file    = "/etc/nginx/certs/selfsigned.key"
    content = file("${local.cert_dir}/selfsigned.key")
  }

  healthcheck {
    test     = ["CMD", "wget", "-qO-", "http://127.0.0.1/nginx-health"]
    interval = "10s"
    timeout  = "5s"
    retries  = 3
  }

  log_driver = "json-file"
  log_opts   = local.log_opts

  wait         = true
  wait_timeout = 60

  depends_on = [docker_container.api, docker_container.web]
}

# ---- LocalStack ----
# Stands in for AWS S3/IAM so backups have an S3-compatible target. Bound to
# 127.0.0.1 only: backup.sh and terraform/aws-local reach it from the host.
# Community edition keeps no state across restarts; re-apply terraform/aws-local.

resource "docker_image" "localstack" {
  count        = var.enable_localstack ? 1 : 0
  name         = var.localstack_image
  keep_locally = true
}

resource "docker_container" "localstack" {
  count   = var.enable_localstack ? 1 : 0
  name    = "${var.name_prefix}-localstack"
  image   = docker_image.localstack[0].image_id
  restart = "unless-stopped"

  env = compact([
    "SERVICES=s3,iam,sts",
    var.localstack_auth_token != "" ? "LOCALSTACK_AUTH_TOKEN=${var.localstack_auth_token}" : "",
  ])

  ports {
    internal = 4566
    external = 4566
    ip       = "127.0.0.1"
  }

  networks_advanced {
    name    = docker_network.app.id
    aliases = ["localstack"]
  }

  log_driver = "json-file"
  log_opts   = local.log_opts
}
