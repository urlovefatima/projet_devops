variable "name" {
  type        = string
  description = "Préfixe de nommage du bucket"
}

variable "versioning_enabled" {
  type        = bool
  description = "Active le versioning du bucket"
  default     = false
}

variable "tags" {
  type        = map(string)
  description = "Tags appliqués à la ressource"
  default     = {}
}
