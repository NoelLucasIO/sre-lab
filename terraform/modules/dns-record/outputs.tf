output "fqdn" {
  description = "Fully qualified name of the A record."
  value       = local.fqdn
}

output "ptr_name" {
  description = "Owner name of the PTR record, or null when create_ptr is false."
  value       = var.create_ptr ? local.ptr_name : null
}
