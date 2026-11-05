# Observability config (Grafana) has its own state so CI can destroy/rebuild envs/lab
# without any path to the shared Prometheus data source. See docs/decisions/0004-state-split.md.
terraform {
  required_version = ">= 1.10"

  backend "pg" {
    schema_name = "observability"
  }
}
