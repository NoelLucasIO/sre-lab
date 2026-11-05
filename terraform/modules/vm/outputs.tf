output "name" {
  description = "libvirt domain name (also the hostname)."
  value       = libvirt_domain.this.name
}

output "fqdn" {
  description = "Fully qualified hostname set by cloud-init."
  value       = local.fqdn
}

output "ipv4" {
  description = "Static IPv4 address, without prefix length."
  value       = local.ip
}

output "mac" {
  description = "Deterministic MAC address of the NIC (derived from name)."
  value       = local.mac
}
