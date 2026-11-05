# Deliberately non-compliant fixtures: every resource here must FAIL its policy.
resource "libvirt_domain" "exposed_console" {
  name = "bad"
  type = "kvm"
  devices = {
    graphics = [{ vnc = { auto_port = true, listen = "0.0.0.0" } }]
  }
}

resource "technitium_record" "unowned" {
  zone  = "noellucas.io"
  name  = "bad.noellucas.io"
  type  = "A"
  value = "192.0.2.1"
}

resource "grafana_data_source" "insecure" {
  type              = "prometheus"
  name              = "bad"
  url               = "https://prom.example"
  json_data_encoded = jsonencode({ httpMethod = "POST", tlsSkipVerify = true })
}
