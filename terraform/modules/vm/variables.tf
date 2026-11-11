variable "name" {
  description = "Short hostname; also the libvirt domain name."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.name))
    error_message = "name must be a lowercase RFC 1123 label (3-32 chars)."
  }
}

variable "domain" {
  description = "DNS domain appended to name for the FQDN."
  type        = string
  default     = "noellucas.io"
}

variable "tags" {
  description = "Ownership/purpose tags, stored on the domain. Policy: env, role and owner are mandatory."
  type        = map(string)
  validation {
    condition     = alltrue([for k in ["env", "role", "owner"] : contains(keys(var.tags), k)])
    error_message = "tags must include env, role and owner."
  }
}

variable "vcpu" {
  description = "Virtual CPU count."
  type        = number
  default     = 2
}

variable "memory_mib" {
  description = "Memory in MiB."
  type        = number
  default     = 4096
}

variable "disk_gib" {
  description = "Root disk size; a thin qcow2 overlay on the base image."
  type        = number
  default     = 40
}

variable "pool" {
  description = "libvirt storage pool for the VM's volumes."
  type        = string
  default     = "990Flash"
}

variable "base_volume_path" {
  description = "Absolute path of the qcow2 cloud image used as the backing store."
  type        = string
}

variable "bridge" {
  description = "Host bridge the NIC attaches to."
  type        = string
  default     = "br0"
}

variable "ipv4_cidr" {
  description = "Static address in CIDR form, e.g. 192.168.2.40/24."
  type        = string
  validation {
    condition     = can(cidrhost(var.ipv4_cidr, 0))
    error_message = "ipv4_cidr must be CIDR notation, e.g. 192.168.2.40/24."
  }
}

variable "gateway" {
  description = "IPv4 default gateway."
  type        = string
}

variable "dns_servers" {
  description = "DNS resolvers written into the guest network config."
  type        = list(string)
}

variable "admin_user" {
  description = "Login user created by cloud-init (key-only, passwordless sudo)."
  type        = string
  default     = "nlucas"
}

variable "ssh_authorized_keys" {
  description = "Public keys for admin_user (automation key + hardware keys)."
  type        = list(string)
  validation {
    condition     = length(var.ssh_authorized_keys) > 0
    error_message = "At least one SSH key is required; password login is disabled."
  }
}

variable "ssh_host_ed25519_private" {
  description = "Managed SSH host private key (OpenSSH format), or null to let the VM generate one on first boot (ADR 0011)."
  type        = string
  default     = null
  sensitive   = true
}

variable "ssh_host_ed25519_public" {
  description = "Public half of ssh_host_ed25519_private (OpenSSH format, no comment needed)."
  type        = string
  default     = null
  validation {
    condition     = var.ssh_host_ed25519_public == null || can(regex("^ssh-ed25519 [A-Za-z0-9+/=]+", var.ssh_host_ed25519_public))
    error_message = "ssh_host_ed25519_public must be an OpenSSH ed25519 public key."
  }
}

