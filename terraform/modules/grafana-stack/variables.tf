variable "folder" {
  description = "Folder that owns everything this module manages."
  type = object({
    uid   = string
    title = string
  })
}

variable "prometheus" {
  description = "Prometheus data source to manage. null = do not manage one (look it up elsewhere)."
  type = object({
    name       = string
    uid        = string
    url        = string
    is_default = optional(bool, false)
    scrape     = optional(string, "15s")
  })
  default = null
}

variable "alertmanager" {
  description = "External Alertmanager data source to manage. null = none. Links use ?alertmanager=<name>."
  type = object({
    name = string
    uid  = string
    url  = string
  })
  default = null

  validation {
    condition     = var.alertmanager == null ? true : can(regex("^[A-Za-z0-9_-]+$", var.alertmanager.name))
    error_message = "Alertmanager data source name must be URL-safe (letters, digits, _ and -): links select it by name."
  }
}

variable "dashboards_dir" {
  description = "Directory of dashboard JSON exports (*.json). Each must carry a stable top-level \"uid\"."
  type        = string
  default     = null
}

variable "alert_rule_groups" {
  description = <<-EOT
    Rule groups keyed by group name. Each rule is a PromQL expression evaluated as an instant query;
    it fires when the result is greater than `threshold`. Write expressions with `bool` comparisons
    (e.g. `up{job="x"} == bool 0`) so a healthy target returns 0 rather than no data.
  EOT
  type = map(object({
    interval_seconds = optional(number, 60)
    rules = list(object({
      name           = string
      expr           = string
      threshold      = optional(number, 0)
      for            = optional(string, "5m")
      datasource_uid = optional(string)
      labels         = optional(map(string), {})
      annotations    = optional(map(string), {})
      no_data_state  = optional(string, "NoData")
      exec_err_state = optional(string, "Error")
    }))
  }))
  default = {}

  validation {
    condition = alltrue(flatten([
      for g in values(var.alert_rule_groups) : [for r in g.rules : contains(keys(r.annotations), "runbook_url")]
    ]))
    error_message = "Every alert rule needs a runbook_url annotation."
  }
}

variable "default_datasource_uid" {
  description = "Data source for rules that don't set datasource_uid. Falls back to the managed Prometheus."
  type        = string
  default     = null
}
