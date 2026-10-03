variable "project_name" {
  type        = string
  description = "Nom du projet (minuscules, chiffres et tirets)"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,30}$", var.project_name))
    error_message = "project_name doit contenir 3 à 30 caractères : minuscules, chiffres et tirets."
  }
}

variable "environment" {
  type        = string
  description = "Environnement de déploiement (dev ou prod)"

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment doit valoir \"dev\" ou \"prod\"."
  }
}

variable "aws_region" {
  type        = string
  description = "Région AWS émulée par Floci"
  default     = "us-east-1"
}

variable "floci_endpoint" {
  type        = string
  description = "URL de l'endpoint local Floci"
  default     = "http://localhost:4566"
}

variable "s3_versioning_enabled" {
  type        = bool
  description = "Active le versioning du bucket S3"
  default     = false
}

variable "dynamodb_hash_key" {
  type        = string
  description = "Nom de la clé de partition de la table DynamoDB"
  default     = "id"
}
