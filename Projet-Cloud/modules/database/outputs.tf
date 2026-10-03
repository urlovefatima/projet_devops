output "resource_name" {
  description = "Nom de la table DynamoDB"
  value       = aws_dynamodb_table.this.name
}

output "resource_arn" {
  description = "ARN de la table DynamoDB"
  value       = aws_dynamodb_table.this.arn
}
