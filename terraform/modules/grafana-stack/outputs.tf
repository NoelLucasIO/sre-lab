output "folder_uid" {
  value = grafana_folder.this.uid
}

output "prometheus_uid" {
  value = try(grafana_data_source.prometheus[0].uid, null)
}

output "dashboard_urls" {
  value = { for k, d in grafana_dashboard.this : k => d.url }
}
