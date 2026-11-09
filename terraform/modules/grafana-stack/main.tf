locals {
  dashboard_files = var.dashboards_dir == null ? toset([]) : fileset(var.dashboards_dir, "*.json")
  dashboards      = { for f in local.dashboard_files : trimsuffix(f, ".json") => jsondecode(file("${var.dashboards_dir}/${f}")) }
  rule_ds_uid     = coalesce(var.default_datasource_uid, try(grafana_data_source.prometheus[0].uid, null), "unset")
}

resource "grafana_folder" "this" {
  uid   = var.folder.uid
  title = var.folder.title
}

resource "grafana_data_source" "prometheus" {
  count = var.prometheus == null ? 0 : 1

  type       = "prometheus"
  name       = var.prometheus.name
  uid        = var.prometheus.uid
  url        = var.prometheus.url
  is_default = var.prometheus.is_default

  json_data_encoded = jsonencode({
    httpMethod     = "POST"
    prometheusType = "Prometheus"
    timeInterval   = var.prometheus.scrape
  })
}

# External Alertmanager (Prometheus implementation): its alerts and silences in Grafana's UI.
# Grafana selects it by name in links (?alertmanager=<name>), so keep the name stable.
resource "grafana_data_source" "alertmanager" {
  count = var.alertmanager == null ? 0 : 1

  type = "alertmanager"
  name = var.alertmanager.name
  uid  = var.alertmanager.uid
  url  = var.alertmanager.url

  json_data_encoded = jsonencode({
    implementation             = "prometheus"
    handleGrafanaManagedAlerts = false
  })
}

resource "grafana_dashboard" "this" {
  for_each = local.dashboards

  folder      = grafana_folder.this.uid
  config_json = jsonencode(each.value)
  overwrite   = true # Git is the source of truth; UI edits get reverted on apply

  lifecycle {
    precondition {
      condition     = can(each.value.uid) && length(try(each.value.uid, "")) > 0
      error_message = "Dashboard ${each.key}.json has no top-level uid; every apply would create a duplicate."
    }
  }
}

resource "grafana_rule_group" "this" {
  for_each = var.alert_rule_groups

  name             = each.key
  folder_uid       = grafana_folder.this.uid
  interval_seconds = each.value.interval_seconds

  dynamic "rule" {
    for_each = each.value.rules
    content {
      name           = rule.value.name
      for            = rule.value.for
      condition      = "B"
      no_data_state  = rule.value.no_data_state
      exec_err_state = rule.value.exec_err_state
      labels         = rule.value.labels
      annotations    = rule.value.annotations

      data {
        ref_id         = "A"
        datasource_uid = coalesce(rule.value.datasource_uid, local.rule_ds_uid)
        relative_time_range {
          from = 600
          to   = 0
        }
        model = jsonencode({ refId = "A", expr = rule.value.expr, instant = true })
      }

      data {
        ref_id         = "B"
        datasource_uid = "__expr__"
        relative_time_range {
          from = 0
          to   = 0
        }
        model = jsonencode({
          refId      = "B"
          type       = "threshold"
          expression = "A"
          conditions = [{ evaluator = { type = "gt", params = [rule.value.threshold] } }]
        })
      }
    }
  }
}
