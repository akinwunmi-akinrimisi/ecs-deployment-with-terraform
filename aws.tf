provider "aws" {
  access_key = var.access_key
  secret_key = var.secret_key
  region     = var.region
  default_tags {
    tags = merge(var.tags, { Name = var.name })
  }
}

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.6"
    }
  }
}
