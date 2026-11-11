# ADR 0011: managed SSH host keys reach cloud-init, and the private key never leaks into
# readable attributes. Plan-only against a mocked libvirt provider: runs on GitHub-hosted runners.
mock_provider "libvirt" {}

variables {
  name                = "test-node"
  base_volume_path    = "/990/VM/base.qcow2"
  ipv4_cidr           = "192.168.2.99/24"
  gateway             = "192.168.2.1"
  dns_servers         = ["192.168.2.45"]
  ssh_authorized_keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestOnlyNotARealKey test"]
  tags                = { env = "test", role = "test", owner = "test" }
}

run "without_managed_key" {
  command = plan

  assert {
    condition     = !strcontains(libvirt_cloudinit_disk.this.user_data, "ssh_keys")
    error_message = "without a managed key, cloud-init must not get ssh_keys (VMs generate their own)"
  }
  assert {
    condition     = !issensitive(libvirt_cloudinit_disk.this.user_data)
    error_message = "without a managed key, user_data must stay readable in plans"
  }
  assert {
    condition     = output.ssh_host_ed25519_public == null
    error_message = "no managed key: the public-key output must be null"
  }
}

run "with_managed_key" {
  command = plan

  variables {
    ssh_host_ed25519_private = "test-private-key-material"
    ssh_host_ed25519_public  = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHostKeyTestOnly"
  }

  assert {
    condition     = issensitive(libvirt_cloudinit_disk.this.user_data)
    error_message = "user_data carries the private key, so it must be sensitive"
  }
  assert {
    condition     = strcontains(nonsensitive(libvirt_cloudinit_disk.this.user_data), "\"ed25519_private\": \"test-private-key-material\"")
    error_message = "cloud-init must receive the managed private key under ssh_keys"
  }
  assert {
    condition     = !issensitive(libvirt_cloudinit_disk.this.meta_data)
    error_message = "meta_data (instance-id) must not depend on the private key"
  }
  assert {
    condition     = !strcontains(libvirt_cloudinit_disk.this.meta_data, "test-private-key-material")
    error_message = "the private key must never appear in meta_data"
  }
  assert {
    condition     = output.ssh_host_ed25519_public == "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHostKeyTestOnly"
    error_message = "the public-key output must pass the managed key through"
  }
}

run "rejects_a_non_ed25519_public_key" {
  command = plan

  variables {
    ssh_host_ed25519_private = "x"
    ssh_host_ed25519_public  = "ssh-rsa AAAAB3NzaC1yc2E"
  }

  expect_failures = [var.ssh_host_ed25519_public]
}
