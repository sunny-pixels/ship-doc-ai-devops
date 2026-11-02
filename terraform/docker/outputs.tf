output "app_url" {
  description = "Public HTTPS URL of the app (self-signed cert)."
  value       = var.https_port == 443 ? "https://localhost" : "https://localhost:${var.https_port}"
}

output "image_tag" {
  description = "Image tag currently deployed. The deploy workflow records this for rollback."
  value       = var.image_tag
}

output "containers" {
  description = "Container names, for docker logs / docker exec."
  value = {
    api   = docker_container.api.name
    web   = docker_container.web.name
    nginx = docker_container.nginx.name
  }
}

output "network" {
  description = "Docker network the stack runs on."
  value       = docker_network.app.name
}

output "data_volume" {
  description = "Named volume holding uploads + Chroma (what backup.sh archives)."
  value       = docker_volume.data.name
}
