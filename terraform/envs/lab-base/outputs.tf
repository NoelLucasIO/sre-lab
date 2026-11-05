output "rocky9_path" {
  description = "Backing-store path consumed by envs/lab (by convention, not remote state)."
  value       = libvirt_volume.rocky9.path
}
