data "aws_caller_identity" "current" {}

locals {
  param_prefix = "/${var.name_prefix}"
  bucket_name  = "${var.name_prefix}-config-${data.aws_caller_identity.current.account_id}"
  game_port    = 15637
}

# Holds everything the instance pulls at boot: compose file, scripts, systemd
# units, rendered settings and (later) mods. Edit files in ../instance, run
# `terraform apply`, then start the server again.
resource "aws_s3_bucket" "config" {
  bucket = local.bucket_name
}

resource "aws_s3_bucket_public_access_block" "config" {
  bucket                  = aws_s3_bucket.config.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "config" {
  bucket = aws_s3_bucket.config.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "config" {
  bucket = aws_s3_bucket.config.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_policy" "config_tls_only" {
  bucket = aws_s3_bucket.config.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.config.arn, "${aws_s3_bucket.config.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

locals {
  instance_files = [
    for f in fileset("${path.module}/../instance", "**") : f
    if !endswith(f, ".gitkeep")
  ]
}

resource "aws_s3_object" "instance_files" {
  for_each = toset(local.instance_files)

  bucket = aws_s3_bucket.config.id
  key    = "instance/${each.value}"
  source = "${path.module}/../instance/${each.value}"
  etag   = filemd5("${path.module}/../instance/${each.value}")
}

resource "aws_s3_object" "server_env" {
  bucket = aws_s3_bucket.config.id
  key    = "instance/server.env"
  content = templatefile("${path.module}/templates/server.env.tftpl", {
    server_name = var.server_name
    slot_count  = var.slot_count
  })
}

resource "aws_s3_object" "idle_env" {
  bucket = aws_s3_bucket.config.id
  key    = "instance/idle.env"
  content = templatefile("${path.module}/templates/idle.env.tftpl", {
    idle_minutes     = var.idle_minutes
    max_uptime_hours = var.max_uptime_hours
    query_port       = local.game_port
    public_address   = aws_eip.server.public_ip
  })
}
