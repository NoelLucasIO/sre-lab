output "name" {
  value = libvirt_domain.this.name
}

output "fqdn" {
  value = local.fqdn
}

output "ipv4" {
  value = local.ip
}

output "mac" {
  value = local.mac
}
