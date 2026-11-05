output "dashboard_urls" {
  description = "Managed dashboard URLs keyed by JSON file name."
  value       = module.grafana.dashboard_urls
}
