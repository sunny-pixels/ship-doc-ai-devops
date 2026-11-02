variable "docker_host" {
  description = "Docker daemon socket Terraform talks to."
  type        = string
  default     = "unix:///var/run/docker.sock"
}

variable "image_tag" {
  description = "Tag of the locally built ultradoc-api / ultradoc-web images (the git SHA in CI)."
  type        = string
}

variable "name_prefix" {
  description = "Prefix for container, network and volume names."
  type        = string
  default     = "ultradoc"
}

# ---- API settings ----

variable "llm_api_key" {
  description = "Groq (or other OpenAI-compatible) API key. Pass via TF_VAR_llm_api_key; never commit it."
  type        = string
  sensitive   = true
}

variable "llm_base_url" {
  description = "OpenAI-compatible endpoint for the LLM."
  type        = string
  default     = "https://api.groq.com/openai/v1"
}

variable "llm_model" {
  description = "Chat model name at the LLM endpoint."
  type        = string
  default     = "openai/gpt-oss-120b"
}

variable "max_upload_mb" {
  description = "Per-file upload limit. Keep in sync with client_max_body_size in nginx/default.conf."
  type        = number
  default     = 10
}

variable "log_level" {
  description = "API log level."
  type        = string
  default     = "INFO"
}

# ---- nginx ----

variable "http_port" {
  description = "Host port for HTTP (redirects to HTTPS)."
  type        = number
  default     = 80
}

variable "https_port" {
  description = "Host port for HTTPS."
  type        = number
  default     = 443
}

variable "nginx_image" {
  description = "nginx image to run as the reverse proxy."
  type        = string
  default     = "nginx:1.27-alpine"
}

variable "nginx_conf_path" {
  description = "Path to the nginx site config. Defaults to the repo's nginx/default.conf."
  type        = string
  default     = null
}

variable "cert_dir" {
  description = "Directory holding selfsigned.crt and selfsigned.key (see scripts/gen-certs.sh). Defaults to the repo's nginx/certs."
  type        = string
  default     = null
}
