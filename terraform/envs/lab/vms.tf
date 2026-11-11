locals {
  # Must match envs/lab-base output rocky9_path (that layer owns the download).
  rocky9_base = "/990/VM/rocky-9-genericcloud-base.qcow2"

  # Host keys come from envs/lab-base (ADR 0011); see host-keys.tf.
  host_public_keys  = try(data.terraform_remote_state.lab_base.outputs.k3s_host_public_keys, {})
  host_private_keys = try(data.terraform_remote_state.lab_base.outputs.k3s_host_private_keys, {})

  ssh_keys = [for f in fileset("${path.module}/../../../keys", "*.pub") : trimspace(file("${path.module}/../../../keys/${f}"))]

  k3s_nodes = {
    k3s-server-1 = { ip = "192.168.2.40", role = "k3s-server", vcpu = 4, memory_mib = 8192 }
    k3s-agent-1  = { ip = "192.168.2.41", role = "k3s-agent", vcpu = 4, memory_mib = 8192 }
    k3s-agent-2  = { ip = "192.168.2.42", role = "k3s-agent", vcpu = 4, memory_mib = 8192 }
  }
}

module "k3s_node" {
  source   = "../../modules/vm"
  for_each = local.k3s_nodes

  name             = each.key
  vcpu             = each.value.vcpu
  memory_mib       = each.value.memory_mib
  disk_gib         = 40
  base_volume_path = local.rocky9_base
  ipv4_cidr        = "${each.value.ip}/24"
  gateway          = "192.168.2.1"
  dns_servers      = ["192.168.2.45"]

  ssh_authorized_keys = local.ssh_keys

  ssh_host_ed25519_private = lookup(local.host_private_keys, each.key, null)
  ssh_host_ed25519_public  = lookup(local.host_public_keys, each.key, null)

  tags = {
    env   = "lab"
    role  = each.value.role
    owner = "nlucas"
  }
}
