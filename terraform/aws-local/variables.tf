variable "localstack_endpoint" {
  description = "LocalStack edge endpoint."
  type        = string
  default     = "http://127.0.0.1:4566"
}

variable "region" {
  description = "AWS region name (any value works on LocalStack)."
  type        = string
  default     = "us-east-1"
}

variable "bucket_name" {
  description = "S3 bucket that holds data-volume backups."
  type        = string
  default     = "ultradoc-backups"
}

variable "backup_retention_days" {
  description = "Days before a backup object expires."
  type        = number
  default     = 30
}

variable "noncurrent_retention_days" {
  description = "Days an overwritten (noncurrent) version is kept before deletion."
  type        = number
  default     = 7
}

variable "force_destroy" {
  description = "Allow terraform destroy to delete a non-empty bucket. Keep false outside of local testing."
  type        = bool
  default     = false
}
