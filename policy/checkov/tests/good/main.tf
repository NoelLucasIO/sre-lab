# Compliant fixtures: every resource here must PASS its policy.
resource "libvirt_domain" "local_console" {
  name = "good"
  type = "kvm"
  devices = {
    graphics = [{ vnc = { auto_port = true, listen = "127.0.0.1" } }]
  }
}

resource "technitium_record" "owned" {
  zone     = "noellucas.io"
  name     = "good.noellucas.io"
  type     = "A"
  value    = "192.0.2.2"
  comments = "managed-by=terraform repo=sre-lab"
}

resource "grafana_data_source" "secure" {
  type              = "prometheus"
  name              = "good"
  url               = "https://prom.example"
  json_data_encoded = jsonencode({ httpMethod = "POST" })
}
