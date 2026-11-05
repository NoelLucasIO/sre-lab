# sre-lab

A home-lab reliability platform, built the way production should be. The service under management
is a Nightscout + tconnectsync stack, so every SLO, alert and drill measures real data.

| Phase | Scope | Status |
|---|---|---|
| 1 | Terraform modules, remote state with enforced locking, policy-as-code | **Done** (2026-11-05) |
| 2 | CI/CD: plan on PR, approval gate, change-risk checks, automatic rollback | Planned |
| 3 | SLIs/SLOs, multi-window burn-rate alerts, on-call routing, runbooks | Planned |
| 4 | AWS via Terraform, offsite backups, timed DR drill, game day, postmortem | Planned |

## Layout

```
docs/decisions/   Architecture decision records
garage/           Garage S3 (rootless Podman quadlet), backup target
keys/             Public SSH keys baked into VMs by cloud-init
policy/           Custom Checkov policies + their self-test
postgres/         Terraform state database bootstrap
terraform/envs/   Root modules: lab (k3s VMs + DNS), lab-base (cloud images), observability (Grafana), prod-lab
terraform/lock-test/  Proof that state locking excludes a second writer
```

## Phase 1 evidence

- **State locking:** a second writer is refused (`terraform/lock-test/run.sh`, PASS); S3 lockfile on Garage
  silently does not lock (ADR 0001).
- **Modules:** `vm` (libvirt + cloud-init), `dns-record` (Technitium A + PTR), `grafana-stack`
  (hand-built Prometheus data source and dashboard adopted via `import`, then `plan`: no changes).
- **Policy-as-code:** tflint (preset `all`) clean; custom Checkov policies proven against
  violating fixtures by `policy/test.sh` (ADR 0003).
- **Rebuild test (2026-11-05):** destroy 18 k3s resources and apply them again, then wait for boot
  and cloud-init on all 3 nodes. **70 s wall clock**, last node ready 59 s after apply. DNS
  resolves, drift `plan` reports no changes, Grafana untouched.

## Decisions

- [ADR 0001: Terraform state backend](docs/decisions/0001-terraform-state-backend.md): tested the
  S3 lock primitive on Garage, found it silently no-ops, moved state locking to Postgres.
- [ADR 0002: Separate state for long-lived artifacts](docs/decisions/0002-state-layering.md)
- [ADR 0003: Policy-as-code layers](docs/decisions/0003-policy-as-code.md): built-in Checkov
  policies evaluated 0 checks here; custom policies are tested against violating fixtures.
- [ADR 0004: Observability config gets its own state](docs/decisions/0004-state-split.md): VM rebuilds
  can no longer reach the shared Prometheus data source.

## Host

Fedora Server 44, rootless Podman quadlets with `Network=host`. Storage: `/990` NVMe xfs for
metadata and databases, `/data` 2×24 TB MD RAID1 xfs for bulk data.
