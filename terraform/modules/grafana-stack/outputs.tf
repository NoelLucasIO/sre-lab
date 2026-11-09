output "folder_uid" {
  description = "UID of the folder that owns this module's dashboards and rules."
  value       = grafana_folder.this.uid
}

output "prometheus_uid" {
  description = "UID of the managed Prometheus data source, or null if not managed here."
  value       = try(grafana_data_source.prometheus[0].uid, null)
}

output "dashboard_urls" {
  description = "Dashboard URLs keyed by JSON file name (without .json)."
  value       = { for k, d in grafana_dashboard.this : k => d.url }
}

output "alertmanager_url" {
  description = "Grafana path that shows the managed Alertmanager's alert groups, or null."
  value       = try("/alerting/groups?alertmanager=${grafana_data_source.alertmanager[0].name}", null)
}
