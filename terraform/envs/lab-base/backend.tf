# Long-lived artifacts (cloud images) live in their own state so `destroy` on envs/lab
# never throws away a 650 MB download. See docs/decisions/0002-state-layering.md.
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
  }
}

provider "libvirt" {
  uri = "qemu:///system"
}
