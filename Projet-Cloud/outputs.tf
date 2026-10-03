output "storage_name" {
  description = "Nom du bucket S3"
  value       = module.storage.resource_name
}

output "storage_arn" {
  description = "ARN du bucket S3"
  value       = module.storage.resource_arn
}

output "database_name" {
  description = "Nom de la table DynamoDB"
  value       = module.database.resource_name
}

output "database_arn" {
  description = "ARN de la table DynamoDB"
  value       = module.database.resource_arn
}
