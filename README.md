# sre-lab

A home-lab reliability platform, built the way production should be. The service under management
is a Nightscout + tconnectsync stack, so every SLO, alert and drill measures real data.

| Phase | Scope | Status |
|---|---|---|
| 1 | Terraform modules, remote state with enforced locking, policy-as-code | In progress |
| 2 | CI/CD: plan on PR, approval gate, change-risk checks, automatic rollback | Planned |
| 3 | SLIs/SLOs, multi-window burn-rate alerts, on-call routing, runbooks | Planned |
| 4 | AWS via Terraform, offsite backups, timed DR drill, game day, postmortem | Planned |

## Layout

```
docs/decisions/   Architecture decision records
garage/           Garage S3 (rootless Podman quadlet), backup target
postgres/         Terraform state database bootstrap
terraform/envs/   Per-environment root modules (lab, prod-lab)
terraform/lock-test/  Proof that state locking excludes a second writer
```

## Decisions

- [ADR 0001: Terraform state backend](docs/decisions/0001-terraform-state-backend.md): tested the
  S3 lock primitive on Garage, found it silently no-ops, moved state locking to Postgres.

## Host

Fedora Server 44, rootless Podman quadlets with `Network=host`. Storage: `/990` NVMe xfs for
metadata and databases, `/data` 2×24 TB MD RAID1 xfs for bulk data.
