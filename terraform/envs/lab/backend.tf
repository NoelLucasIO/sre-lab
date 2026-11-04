# State: Postgres advisory locks (see docs/decisions/0001-terraform-state-backend.md).
# Connection string comes from PG_CONN_STR (~/.config/terraform/pg.env), never from Git.
terraform {
  required_version = ">= 1.10"

  backend "pg" {
    schema_name = "lab"
  }
}
