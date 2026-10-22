terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  # State is local by default (gitignored; it contains no secrets). To move it
  # to S3 with locking, create the bucket once by hand and uncomment:
  #
  # backend "s3" {
  #   bucket       = "YOUR-TFSTATE-BUCKET"
  #   key          = "enshrouded/terraform.tfstate"
  #   region       = "us-east-1"
  #   use_lockfile = true
  # }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.name_prefix
      ManagedBy = "terraform"
    }
  }
}
