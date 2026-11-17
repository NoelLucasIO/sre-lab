# ADR 0012: Lab VM DNS is owned by NIOS IPAM, not Terraform

**Status:** accepted (2026-11-17) · **Phase:** 4 · Supersedes the DNS part of `envs/lab` (Phase 1 `dns-record` module)

## Context

- Until 2026-11-16, Technitium on fedora was the primary for `noellucas.io` and `2.168.192.in-addr.arpa`, and `envs/lab` created the A and PTR records for the three k3s nodes through `modules/dns-record` with a Zones-only Technitium token.
- On 2026-11-16 the home lab cut over to Infoblox NIOS (192.168.2.25) as primary for both zones. Technitium now holds them as secondaries, Unbound on `gw` forwards to both, and Kea DDNS updates NIOS.
- Converting a Technitium zone to a secondary recreates it, which dropped the token user's per-zone permissions. The nightly drift check failed the next morning (run #15, issue #43): every `technitium_record` read returned `Access was denied`.
- Restoring the permission would only hide the real problem: a secondary zone is read-only, so the next apply that touches DNS would fail, and any change made in NIOS would show up as drift against a copy.

## Decision

- NIOS IPAM is the source of truth for lab VM addresses and DNS. The k3s nodes keep their static addresses (192.168.2.40–42, outside the Kea pool); their A and PTR records live in NIOS, managed with the rest of the lab VMs by the `ipam-vm` Ansible project in the homelab repo.
- `envs/lab` stops managing DNS. The records are forgotten with a `removed` block (`destroy = false`), not destroyed: they already exist in the primary.
- Rollout is two changes:
  1. **Forget:** the `removed` block replaces the `k3s_dns` module call. Terraform does not refresh resources it is about to forget (checked on 1.17.1), so this plans and applies without restoring the token's zone permissions.
  2. **Clean up** (after apply, plan shows `No changes`): delete the `removed` block, the `technitium` provider and its lock entry, `modules/dns-record`, Checkov policy `CKV2_SRELAB_2` and its fixtures, `technitium.env` from the workflows and `ci/runner/install.sh`, and finally the Technitium token and user.

## Consequences

- `envs/lab` needs one credential fewer on the runner (ADR 0005): libvirt and Postgres only.
- A destroy-and-rebuild of `envs/lab` no longer touches DNS. The records survive in NIOS because the addresses are static, so the DR drill's "DNS resolves" check now depends on NIOS being up rather than on Terraform.
- The NIOS appliance is rebuilt every 60 days for its temporary licence; its config backup carries the records across. Nothing in this repo checks for them any more: a rebuild that loses them is no longer caught by the drift check.
- Terraform no longer proves the "Technitium A + PTR" module claim in the Phase 1 evidence; the README records the change rather than rewriting history.

## Alternatives

- **Re-grant View on the secondaries and keep managing records there:** turns the check green but manages a read-only copy. Rejected.
- **Manage the records in NIOS with the `infobloxopen/infoblox` provider:** keeps DNS in Terraform, but adds a NIOS credential to the runner and makes every nightly plan of `envs/lab` fail while the appliance is down or being rebuilt. It also splits ownership of lab VM DNS between Terraform (k3s) and Ansible (`ipam-vm`, everything else).
