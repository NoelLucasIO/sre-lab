output "k3s_nodes" {
  description = "Feeds the Ansible inventory (Terraform provisions, Ansible configures)."
  value       = { for k, m in module.k3s_node : k => { fqdn = m.fqdn, ip = m.ipv4, mac = m.mac } }
}

output "known_hosts" {
  description = "Pinned host keys: the content of ci/runner/known_hosts (ADR 0011). Empty until envs/lab-base has the keys."
  value = join("", [for k, m in module.k3s_node :
    "${m.fqdn},${m.ipv4} ${m.ssh_host_ed25519_public}\n" if m.ssh_host_ed25519_public != null
  ])
}
