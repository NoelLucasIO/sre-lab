# SSH host identity for the k3s VMs (ADR 0011). It lives here, not in envs/lab, so destroying and
# rebuilding the VMs keeps their host keys: the runner's pinned known_hosts stays valid and a
# rebuild needs no trust-on-first-use (DR drill 2026-11-11, finding 1).
# The private keys are in this root's Postgres state (already treated as secret) and nowhere in Git.
locals {
  # Must match the keys of local.k3s_nodes in envs/lab; envs/lab fails its plan if one is missing.
  k3s_hosts = ["k3s-server-1", "k3s-agent-1", "k3s-agent-2"]
}

resource "tls_private_key" "k3s_host" {
  for_each  = toset(local.k3s_hosts)
  algorithm = "ED25519"

  # Rotating a host key is a deliberate change (new known_hosts commit), never a side effect.
  lifecycle {
    prevent_destroy = true
  }
}
