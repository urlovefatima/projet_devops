module "storage" {
  source = "./modules/storage"

  name               = local.resource_prefix
  versioning_enabled = var.s3_versioning_enabled
  tags               = local.common_tags
}

module "database" {
  source = "./modules/database"

  name     = local.resource_prefix
  hash_key = var.dynamodb_hash_key
  tags     = local.common_tags
}
