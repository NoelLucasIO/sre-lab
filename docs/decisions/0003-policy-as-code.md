# ADR 0003: Policy-as-code layers

- **Status:** Accepted
- **Date:** 2026-11-05

## Context

Phase 1 calls for policy-as-code (tflint + Checkov) gating every change. The obvious setup
(run Checkov's built-in policies) was measured before being trusted.

## Evidence

- Checkov 3.4.3 with built-in policies on this repo: **0 checks evaluated across 20 resources.**
  Its library targets AWS/Azure/GCP/Kubernetes; nothing covers libvirt, Grafana or Technitium.
  A green run proved nothing.
- Checkov cannot parse `modules/grafana-stack` (2 parsing errors): its HCL parser rejects an
  attribute named `for`, which `grafana_rule_group` requires. tflint, which uses Terraform's own
  parser, reads it fine.
- A first draft of `CKV2_SRELAB_3` (string match on `json_data_encoded`) passed a deliberately
  insecure fixture. Checkov renders `jsonencode()` into an object, so the rule now matches the key.
  This was caught only because every policy is tested against a violating fixture.
- tflint 0.65.0 (`terraform` ruleset, preset `all`): 25 findings on first run, all documentation
  and module-structure; fixed, now 0.

## Decision

Three layers, each enforcing what it can actually evaluate:

| Layer | Runs | Enforces |
|---|---|---|
| Terraform `validation` / `precondition` | every `plan` | VM tags (env/role/owner), SSH keys present, name formats, IPs in reverse zone, dashboard UIDs, alert `runbook_url` |
| tflint (`.tflint.hcl`) | pre-merge | pinned versions, typed + documented variables/outputs, standard module layout, unused code |
| Checkov custom policies (`policy/checkov`) | pre-merge | VNC console loopback-only, DNS records tagged `managed-by=terraform`, Grafana data sources never skip TLS verification |

`policy/test.sh` runs each custom policy against `tests/bad` (must fail) and `tests/good`
(must pass). CI runs it before trusting a Checkov result.

## Consequences

- The VM tag rule lives in Terraform validation, not Checkov: Checkov can't evaluate
  `jsonencode(var.tags)` across a module boundary, so a Checkov version of it can never pass.
- `grafana-stack` is outside Checkov's view; its TLS guarantee is structural (the module's
  `json_data_encoded` has no `tlsSkipVerify` input) and tflint still lints it.
- Adding a provider means asking which layer can see its resources before assuming coverage.
