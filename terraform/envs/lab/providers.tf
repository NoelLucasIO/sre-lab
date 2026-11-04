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
  }
}

# URL and service-account token come from GRAFANA_URL / GRAFANA_AUTH (~/.config/terraform/grafana.env).
provider "grafana" {}

provider "libvirt" {
  uri = "qemu:///system"
}
