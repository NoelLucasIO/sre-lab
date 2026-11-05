output "k3s_nodes" {
  description = "Feeds the Ansible inventory (Terraform provisions, Ansible configures)."
  value       = { for k, m in module.k3s_node : k => { fqdn = m.fqdn, ip = m.ipv4, mac = m.mac } }
}
