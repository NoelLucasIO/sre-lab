output "fqdn" {
  value = local.fqdn
}

output "ptr_name" {
  value = var.create_ptr ? local.ptr_name : null
}
