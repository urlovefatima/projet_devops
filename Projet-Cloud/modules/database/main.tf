resource "aws_dynamodb_table" "this" {
  name         = "${var.name}-table"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = var.hash_key
  tags         = var.tags

  attribute {
    name = var.hash_key
    type = "S"
  }
}
