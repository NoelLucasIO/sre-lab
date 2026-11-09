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

  # Alertmanager on fedora (prometheus/alertmanager.container). Grafana uses the host network,
  # so loopback reaches it; the name is what PagerDuty links select (prometheus/alertmanager.yml).
  alertmanager = {
    name = "sre-lab-alertmanager"
    uid  = "sre-lab-alertmanager"
    url  = "http://127.0.0.1:9095"
  }

  dashboards_dir = "${path.module}/dashboards"

  # SLO alerting lives in Prometheus (prometheus/slo, prometheus/rules; ADR 0008), not in Grafana.
  alert_rule_groups = {}
}
