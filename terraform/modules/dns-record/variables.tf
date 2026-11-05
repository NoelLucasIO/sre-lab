variable "name" {
  description = "Short hostname; the record is name.zone."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.name))
    error_message = "name must be a single lowercase DNS label."
  }
}

variable "zone" {
  description = "Forward zone that holds the A record."
  type        = string
  default     = "noellucas.io"
}

variable "ipv4" {
  description = "Address for the A record (and the PTR, if enabled)."
  type        = string
  validation {
    condition     = can(cidrhost("${var.ipv4}/32", 0))
    error_message = "ipv4 must be a plain IPv4 address."
  }
}

variable "reverse_zone" {
  description = "Reverse zone for the PTR. The address must fall inside it."
  type        = string
  default     = "2.168.192.in-addr.arpa"
}

variable "create_ptr" {
  type    = bool
  default = true
}

variable "ttl" {
  type    = number
  default = 300
}
