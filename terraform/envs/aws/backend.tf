# Offsite backup target and cost guardrail. Applied by CI with the sre-lab-apply role (OIDC);
# the roles themselves live in envs/aws-bootstrap. See docs/decisions/0009-aws-account-and-ci-trust.md.
terraform {
  required_version = ">= 1.10"

  backend "pg" {
    schema_name = "aws"
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
      root       = "aws"
    }
  }
}
