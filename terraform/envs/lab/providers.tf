terraform {
  required_providers {
    grafana = {
      source  = "grafana/grafana"
      version = "~> 4.53"
    }
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.9.9"
    }
    technitium = {
      source  = "darkhonor/technitium"
      version = "~> 1.3"
    }
  }
}

# URL and service-account token come from GRAFANA_URL / GRAFANA_AUTH (~/.config/terraform/grafana.env).
provider "grafana" {}

provider "libvirt" {
  uri = "qemu:///system"
}

# Token comes from TECHNITIUM_API_TOKEN (~/.config/terraform/technitium.env): a Zones-only user.
provider "technitium" {
  server_url = "http://127.0.0.1:5380"
}
