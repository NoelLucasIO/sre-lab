# Long-lived artifacts (cloud images, VM host keys) live in their own state so `destroy` on envs/lab
# never throws away a 650 MB download or the VMs' host identity. See ADR 0002 and ADR 0011.
terraform {
  required_version = ">= 1.10"

  backend "pg" {
    schema_name = "lab_base"
  }

  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.9.9"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "libvirt" {
  uri = "qemu:///system"
}
