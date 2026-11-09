output "dashboard_urls" {
  description = "Managed dashboard URLs keyed by JSON file name."
  value       = module.grafana.dashboard_urls
}

output "alertmanager_url" {
  description = "Grafana path for the sre-lab Alertmanager's alert groups."
  value       = module.grafana.alertmanager_url
}
