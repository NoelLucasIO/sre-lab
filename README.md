# sre-lab

A home-lab reliability platform, built the way production should be. The service under management
is a Nightscout + tconnectsync stack, so every SLO, alert and drill measures real data.

| Phase | Scope | Status |
|---|---|---|
| 1 | Terraform modules, remote state with enforced locking, policy-as-code | **Done** (2026-11-05) |
| 2 | CI/CD: plan on PR, approval gate, change-risk checks, automatic rollback | **Done** (2026-11-06) |
| 3 | SLIs/SLOs, multi-window burn-rate alerts, on-call routing, runbooks | **Live** (2026-11-09); alert-tuning week in progress |
| 4 | AWS via Terraform, offsite backups, timed DR drill, game day, postmortem | **In progress**: AWS foundation done (2026-11-09); backups next |

## Layout

```
.github/workflows/    terraform (plan/gate/apply) · drift (nightly) · k3s (Ansible) · nightscout (deploy + rollback)
                      exporter (test, build, GHCR) · rules (Sloth drift, promtool tests, Alertmanager routing)
                      backup (script tests on PRs, nightly offsite copy to S3, weekly restore test)
backup/               Nightscout backups: mongodump timer (fedora), offsite copy, restore check + self-test
ansible/              k3s via the pinned k3s.orchestration collection; namespace-scoped deployer for the app pipeline
ci/                   change-risk gate, self-hosted runner install, Nightscout deploy/health/rollback scripts + tests
docs/decisions/       Architecture decision records
docs/postmortems/     Blameless postmortems · docs/alert-log.md: every alert and whether it needed action
docs/slos.md          SLO definitions and the measurements behind them
docs/runbooks/        One runbook per alert, every command executed before merge
exporter/             Nightscout SLI exporter (stdlib Python, tests, Dockerfile)
garage/               Garage S3 (rootless Podman quadlet), local backup tier and its scoped keys
k8s/nightscout/       Nightscout, MongoDB and tconnectsync on k3s (kustomize, digest-pinned images)
keys/                 Public SSH keys baked into VMs by cloud-init
policy/               Custom Checkov policies + their self-test
postgres/             Terraform state database bootstrap
prometheus/           SLO specs (Sloth), generated + hand-written rules and their tests, scrape fragments,
                      Blackbox and Alertmanager config, quadlets for the monitoring side
terraform/envs/       Root modules: lab (k3s VMs + DNS), lab-base (cloud images), observability (Grafana + SLO
                      dashboard), aws (backup bucket, budget), aws-bootstrap (GitHub OIDC trust; human-applied), prod-lab
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

## Phase 2 evidence

- **Change control as code:** every infrastructure change goes PR → `terraform plan` posted as a
  comment → merge → apply of that exact saved plan, only after approval in the `lab` environment
  (required reviewer, no admin bypass). Plans never leave the runner (public repo).
- **Change-risk gate:** a plan that destroys or replaces more than 2 resources, or touches anything
  tagged `critical`, fails the PR unless it carries `override-risk`. Proven on
  [PR #3](https://github.com/NoelLucasIO/sre-lab/pull/3): blocked a 9-replacement plan, then
  overridden and approved on record.
- **Drift detection:** nightly plan of every root; drift opens an issue, a return to sync closes it.
  Proven with an out-of-band Grafana change and its revert.
- **Terraform provisions, Ansible configures:** the k3s inventory is generated from
  `terraform output`; the cluster converges from CI and is verified Ready. A PR check resolves every
  module and filter the collection uses, after an undeclared upstream dependency broke a converge (ADR 0006).
- **Least privilege for the app pipeline:** a deployer account scoped to one namespace, proven in CI
  with `kubectl auth can-i` in both directions (3 allowed, 6 denied).
- **Automatic rollback, tested with a broken release:** Nightscout deploys behind approval, then a
  health check requires the authenticated API to answer and the newest CGM reading to be under
  10 minutes old. A release pointing at a nonexistent image digest passed every static gate
  (render, digest policy, server-side dry-run); after approval, with no further input, the rollout
  failed, `rollout undo` restored the previous version, its health was re-verified, and
  [issue #12](https://github.com/NoelLucasIO/sre-lab/issues/12) was opened. The old pod served
  throughout (`maxUnavailable: 0`). Reverted on `main` in
  [PR #13](https://github.com/NoelLucasIO/sre-lab/pull/13).
- **Tested pipeline logic:** the deploy and health-check scripts run against a fake `kubectl` and
  `curl` in 19 cases covering every failure path; 5 deliberately planted bugs were all caught.
- **Hardened self-hosted runner:** a locked-down system user under a sandboxed systemd unit; six
  runner and workflow failures diagnosed by evidence and bisection, each recorded in ADR 0005.

## Phase 3 evidence

- **Targets set from measured data, not guessed:** the plan's sync SLO ("pulls within 15 minutes,
  99%") would have been met **6.4%** of the time (1,184 events: p50 44 min, p99 83 min). The delay
  was traced to Tandem Source's upload cadence plus tconnectsync's adaptive sleep, capped at 25
  minutes (read in its source). The SLO was split by who can act: poll success (ours, pages) and
  end-to-end latency (mostly upstream, ticket only). A fix (fixed 5-minute polling) runs on the
  copy as an A/B test against the live instance before it touches production
  ([`docs/slos.md`](docs/slos.md)).
- **Freshness target validated against history:** 99.24% over 5 days; the only budget spent was a
  CGM sensor change, matched to the minute. Both instances go stale together during a sensor
  warm-up, so an inhibit rule keeps it from paging while the SLO still counts it.
- **SLIs measured from outside the cluster:** an exporter (digest-pinned, least-privilege
  ServiceAccount proven with `auth can-i` both ways, secret never in logs or metrics, CI-asserted)
  and authenticated Blackbox probes through every node's ingress, checking the response body so an
  error page is not "up" (ADR 0008).
- **Burn-rate alerting, generated and tested:** Sloth multi-window, multi-burn-rate rules over 28
  days, regenerated in CI and required to match. `promtool test rules` drives synthetic series
  through the real rules (what pages, what tickets, what stays quiet); deliberate rule mutations
  were all caught. Testing found a real bug before it mattered: event-sparse SLIs produced NaN
  ratios that would have hidden the error budget for 28 days.
- **On-call path proven end to end:** Alertmanager routes pages to PagerDuty at high urgency and
  tickets at low urgency, with routing tests in CI. A synthetic page reached the phone in about 25
  seconds with its runbook link and resolved itself; a real low-urgency ticket did not wake anyone.
  An external dead man's switch (healthchecks.io) pages if the monitoring stack itself goes silent.
- **Runbooks that work:** one per alert, starting with "upstream or us?". Every command was run
  before merge, which caught two that would have failed during an incident.
- **Urgency that does not depend on a vendor plan:** pages and tickets go to separate PagerDuty
  services, the ticket service fixed at low urgency, so a lapsed trial feature cannot turn a ticket
  into a 3 a.m. call.
- **SLO dashboard as code:** error budgets, burn rates, firing alerts and copy-vs-live SLIs in one
  Grafana dashboard managed through the Phase 1 `grafana-stack` module.

## Phase 4 evidence (in progress)

- **AWS with zero long-lived CI credentials:** a dedicated account; root locked behind two hardware
  keys with no access keys; people sign in through IAM Identity Center with 1-hour sessions. CI
  exchanges GitHub's OIDC token for short-lived credentials: a read-only role for every plan and the
  nightly drift check, and an apply role trusted only for the approval-gated `lab` environment,
  scoped to the two things it manages and explicitly denied reading or deleting backups.
- **CI cannot widen its own permissions:** the OIDC provider and the roles live in a separate root
  applied only by a human; CI lints it on every PR and drift-checks it nightly but cannot apply it
  (ADR 0009).
- **Trust bound to immutable IDs:** the first CI run was denied because GitHub now issues
  `repo:OWNER@ID/REPO@ID` subjects for new repositories; the trust policies match the numeric owner
  and repository IDs, so a recreated repository with the same name cannot assume the roles.
- **Offsite target and cost guardrail, Terraform only:** an encrypted, versioned backup bucket
  (public access blocked, TLS required, `prevent_destroy`; Glacier after 30 days, expiry after 365)
  and a $5 monthly budget that excludes credits, so it alerts on real spend. Checkov now runs all
  built-in policies: 95 pass, 4 skips each justified inline.

## Decisions

- [ADR 0001: Terraform state backend](docs/decisions/0001-terraform-state-backend.md): tested the
  S3 lock primitive on Garage, found it silently no-ops, moved state locking to Postgres.
- [ADR 0002: Separate state for long-lived artifacts](docs/decisions/0002-state-layering.md)
- [ADR 0003: Policy-as-code layers](docs/decisions/0003-policy-as-code.md): built-in Checkov
  policies evaluated 0 checks on the libvirt/Grafana/DNS code; custom policies are tested against
  violating fixtures. (The AWS roots now get the full built-in set.)
- [ADR 0004: Observability config gets its own state](docs/decisions/0004-state-split.md): VM rebuilds
  can no longer reach the shared Prometheus data source.
- [ADR 0005: Self-hosted runner trust boundary](docs/decisions/0005-runner-trust-boundary.md): what
  the runner can and cannot reach, and the failures that shaped its unit.
- [ADR 0006: Configuration management](docs/decisions/0006-config-management.md): Ansible only from
  CI, inventory from Terraform, versions chosen from the support matrix.
- [ADR 0007: App delivery and rollback](docs/decisions/0007-app-delivery-and-rollback.md): a full
  Nightscout copy on k3s, digest pinning, scoped deploy access, and the rollback test result.
- [ADR 0008: SLO monitoring placement](docs/decisions/0008-slo-monitoring-placement.md): SLOs
  evaluated outside the cluster on fedora's Prometheus; the repo owns only its rule and scrape fragments.
- [ADR 0009: AWS account and CI trust](docs/decisions/0009-aws-account-and-ci-trust.md): Paid plan
  so backups survive, OIDC roles split by what a job can do, and a trust anchor CI cannot apply.
- [ADR 0010: Backups](docs/decisions/0010-backups.md): two stages because the database is reachable
  only by its owner; write-only and read-only keys and roles; a weekly restore test that needs
  nothing from the lab.

## Host

Fedora Server 44, rootless Podman quadlets with `Network=host`. Storage: `/990` NVMe xfs for
metadata and databases, `/data` 2×24 TB MD RAID1 xfs for bulk data. k3s v1.37 on three Rocky 9
VMs (libvirt) built by `terraform/envs/lab`.
