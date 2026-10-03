variable "name" {
  type        = string
  description = "Préfixe de nommage de la table"
}

variable "hash_key" {
  type        = string
  description = "Nom de la clé de partition (type String)"
  default     = "id"
}

variable "tags" {
  type        = map(string)
  description = "Tags appliqués à la ressource"
  default     = {}
}
