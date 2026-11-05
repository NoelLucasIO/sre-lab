terraform {
  required_providers {
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

provider "libvirt" {
  uri = "qemu:///system"
}

# Token comes from TECHNITIUM_API_TOKEN (~/.config/terraform/technitium.env): a Zones-only user.
provider "technitium" {
  server_url = "http://127.0.0.1:5380"
}
