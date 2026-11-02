terraform {
  required_version = ">= 1.5"

  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
  }

  # Local state. On the VM the deploy workflow points this at a fixed path
  # outside the runner's workspace:
  #   terraform init -backend-config="path=/opt/ultradoc/state/docker.tfstate"
  backend "local" {}
}

provider "docker" {
  host = var.docker_host
}
