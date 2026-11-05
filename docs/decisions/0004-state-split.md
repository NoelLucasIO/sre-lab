# ADR 0004: Observability config gets its own state

- **Status:** Accepted
- **Date:** 2026-11-05

## Context

`envs/lab` held both the disposable k3s VMs and the Grafana config, including the default
Prometheus data source every dashboard depends on. The Phase 1 rebuild test had to use
`-target` to avoid destroying it. Phase 2 CI will run plans, applies and rebuilds automatically;
a destroy of `envs/lab` must not be able to touch shared observability.

## Decision

- New root `terraform/envs/observability` (state schema `observability`) owns the
  `grafana-stack` module: folder, Prometheus data source, dashboards, and later the SLO alert rules.
- `envs/lab` (schema `lab`) owns only workloads: k3s VMs and their DNS records.
- The move used config-driven `import` blocks in the new root and a `removed { destroy = false }`
  block in the old one, applied in that order so the resources always had an owner. Both
  changes were reviewed in `plan` first; nothing was destroyed or recreated.

## Evidence (2026-11-05)

- observability: `3 imported, 0 added, 1 changed, 0 destroyed`. The one change is the
  write-only `overwrite = true` flag, which Grafana does not return on import.
- lab: `0 added, 0 changed, 0 destroyed`, three resources forgotten.
- Afterwards both roots plan `No changes`; data source health `OK`; dashboard still in `sre-lab`.

## Consequences

- `terraform destroy` in `envs/lab` is now safe without `-target`.
- Each root's lock file only pins the providers it uses (lab: libvirt + technitium;
  observability: grafana), so a provider bump has a smaller blast radius.
- CI runs each root as a separate job with its own credentials; the VM job never needs the
  Grafana token.
