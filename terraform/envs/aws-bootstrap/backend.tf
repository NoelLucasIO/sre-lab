# Trust anchor for the AWS account: GitHub OIDC provider and the CI roles.
# Applied locally by a human with short-lived IAM Identity Center credentials, never by CI:
# CI must not be able to widen its own permissions. See docs/decisions/0009-aws-account-and-ci-trust.md.
terraform {
  required_version = ">= 1.10"

  backend "pg" {
    schema_name = "aws_bootstrap"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.72"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      project    = "sre-lab"
      managed-by = "terraform"
      root       = "aws-bootstrap"
    }
  }
}
