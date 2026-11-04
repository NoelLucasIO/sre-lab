module "grafana" {
  source = "../../modules/grafana-stack"

  folder = {
    uid   = "sre-lab"
    title = "sre-lab"
  }

  # Hand-built in the UI; adopted below via import, not recreated.
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

# Phase 1 step 5: bring hand-built resources under code. Config-driven import shows up in
# `terraform plan` (and in the PR) before anything changes; delete these blocks after the first apply.
import {
  to = module.grafana.grafana_data_source.prometheus[0]
  id = "bg14884efuy9sd"
}

import {
  to = module.grafana.grafana_dashboard.this["node-exporter"]
  id = "rYdddlPWk"
}
