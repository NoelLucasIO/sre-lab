# ADR 0002: Separate state for long-lived artifacts

- **Status:** Accepted
- **Date:** 2026-11-04
- **Amended by:** [ADR 0011](0011-managed-host-keys.md) (2026-11-11): `envs/lab` reads the VM host keys from `lab_base` state, the one remote-state read between the layers.

## Context

Phase 1's exit test is `terraform destroy && terraform apply` rebuilding the k3s VMs cleanly.
The VMs boot from a 646 MB Rocky 9 cloud image. If the image lived in the same state as the VMs,
every rebuild test would delete and re-download it: wasted bandwidth and minutes, and a rebuild
that depends on an upstream mirror being up.

## Decision

- `terraform/envs/lab-base` (state schema `lab_base`) owns long-lived artifacts: cloud images.
- `terraform/envs/lab` (state schema `lab`) owns workloads: VMs, Grafana config.
- The workload layer references the image by its well-known path, not via `terraform_remote_state`,
  so the two layers stay independently plannable and the workload layer needs no read access
  to the base layer's state.

## Consequences

- `destroy` on `envs/lab` is cheap and safe to run as a routine rebuild test.
- The image is not re-verified on every run. Its upstream SHA256 is recorded in
  `envs/lab-base/main.tf`; refreshing it is a deliberate change to that layer.
- If the path convention breaks (image renamed), `envs/lab` fails at VM create time with a
  missing backing file, which is loud and early.
