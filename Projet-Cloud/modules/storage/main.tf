resource "aws_s3_bucket" "this" {
  bucket        = "${var.name}-storage"
  force_destroy = true
  tags          = var.tags
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = var.versioning_enabled ? "Enabled" : "Suspended"
  }
}
