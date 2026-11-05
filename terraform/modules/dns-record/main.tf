locals {
  fqdn     = "${var.name}.${var.zone}"
  ptr_name = "${join(".", reverse(split(".", var.ipv4)))}.in-addr.arpa"
  comment  = "managed-by=terraform repo=sre-lab"
}

# The provider has no auto-PTR, so forward and reverse are separate records.
resource "technitium_record" "a" {
  zone     = var.zone
  name     = local.fqdn
  type     = "A"
  value    = var.ipv4
  ttl      = var.ttl
  comments = local.comment
}

resource "technitium_record" "ptr" {
  count = var.create_ptr ? 1 : 0

  zone     = var.reverse_zone
  name     = local.ptr_name
  type     = "PTR"
  value    = local.fqdn
  ttl      = var.ttl
  comments = local.comment

  lifecycle {
    precondition {
      condition     = endswith(local.ptr_name, ".${var.reverse_zone}")
      error_message = "${var.ipv4} is outside reverse zone ${var.reverse_zone}; set create_ptr = false or the right reverse_zone."
    }
  }
}
