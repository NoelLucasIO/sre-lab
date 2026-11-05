module "grafana" {
  source = "../../modules/grafana-stack"

  folder = {
    uid   = "sre-lab"
    title = "sre-lab"
  }

  prometheus = {
    name       = "prometheus"
    uid        = "bg14884efuy9sd"
    url        = "https://prom.noellucas.io"
    is_default = true
  }

  dashboards_dir = "${path.module}/dashboards"

  # First rules arrive with the Phase 3 SLOs (each needs a runbook_url).
  alert_rule_groups = {}
}
