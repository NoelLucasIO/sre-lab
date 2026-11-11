output "rocky9_path" {
  description = "Backing-store path consumed by envs/lab (by convention, not remote state)."
  value       = libvirt_volume.rocky9.path
}

# Two outputs, not one: remote state keeps per-output sensitivity, so the public keys stay
# readable in envs/lab (plans, known_hosts) while the private keys stay redacted (ADR 0011).
output "k3s_host_public_keys" {
  description = "OpenSSH ED25519 public host key per k3s VM."
  value       = { for k, v in tls_private_key.k3s_host : k => trimspace(v.public_key_openssh) }
}

output "k3s_host_private_keys" {
  description = "OpenSSH ED25519 private host key per k3s VM; read only by envs/lab for cloud-init."
  sensitive   = true
  value       = { for k, v in tls_private_key.k3s_host : k => v.private_key_openssh }
}
