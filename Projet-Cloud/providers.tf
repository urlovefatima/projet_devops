# Le provider AWS est redirigé vers Floci (endpoint local) et non vers le vrai AWS.
provider "aws" {
  region     = var.aws_region
  access_key = "test" # fausses credentials : Floci accepte toute valeur non vide
  secret_key = "test"

  # Pas d'appel au vrai AWS pour valider le compte ou les credentials
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  # Les buckets sont adressés en /bucket plutôt que bucket.localhost
  s3_use_path_style = true

  endpoints {
    s3       = var.floci_endpoint
    dynamodb = var.floci_endpoint
    sts      = var.floci_endpoint
    iam      = var.floci_endpoint
  }
}
