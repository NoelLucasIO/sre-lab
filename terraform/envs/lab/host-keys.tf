# Host keys are generated and kept in envs/lab-base (ADR 0011), so destroying this root does not
# change them. Read-only view of that state; PG_CONN_STR comes from the environment, as for the backend.
data "terraform_remote_state" "lab_base" {
  backend = "pg"
  config = {
    schema_name = "lab_base"
  }
}

# Until envs/lab-base has a key for every node, those VMs fall back to keys generated on first boot
# (the old behaviour) and known_hosts cannot be rendered for them. A check warns but does not fail:
# the first rollout plans this root before envs/lab-base has been applied.
check "host_keys_managed" {
  assert {
    condition     = alltrue([for k in keys(local.k3s_nodes) : contains(keys(local.host_public_keys), k)])
    error_message = "envs/lab-base has no host key for some k3s node: apply envs/lab-base first (ADR 0011)."
  }
}
