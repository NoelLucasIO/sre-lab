# k3s node DNS is owned by NIOS IPAM since the 2026-11-16 cutover (ADR 0012).
# Forget the old Technitium records without deleting them: Technitium is now a
# read-only secondary of NIOS, and the same records live in the primary.
# Remove this block, the technitium provider and modules/dns-record once applied.
removed {
  from = module.k3s_dns

  lifecycle {
    destroy = false
  }
}
