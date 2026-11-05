# ADR 0005: Self-hosted runner trust boundary

- **Status:** Accepted
- **Date:** 2026-11-05

## Context

Plans and applies must run on fedora (libvirt, Postgres state, Technitium and Grafana are all
LAN-only). The repo is public, and GitHub advises against self-hosted runners on public repos:
a fork PR can rewrite the workflow and execute arbitrary code on the runner host.

## Decision

1. **Untrusted code never reaches fedora.** fmt, tflint, Checkov and `policy/test.sh` run on
   GitHub-hosted runners. Jobs on the `fedora` runner run only for pushes and PRs whose head
   branch is in this repo; fork PRs are excluded by the job condition and additionally
   require maintainer approval (Settings > Actions > General).
2. **Applies need a human.** Apply jobs target a `lab` environment with a required reviewer.
3. **The runner is a separate, locked-down identity.** System user `gh-runner`: no login shell,
   no sudo, member of `libvirt` only. A hardened systemd unit (`ci/runner/gh-runner.service`)
   adds an empty capability set, `NoNewPrivileges`, read-only system, no access to `/home`,
   private `/tmp` and devices.
4. **Secrets stay on the runner host, not in GitHub.** The runner holds its own copies of the
   least-privilege credentials: the `tfstate` role (no superuser), the Grafana service account,
   and the Technitium token (Zones-only, two zones). GitHub Actions secrets hold none of them,
   so a workflow on a GitHub-hosted runner cannot exfiltrate them.

## Blast radius if a runner job is compromised

| Reachable | Not reachable |
|---|---|
| lab VMs via libvirt, Terraform state (`tfstate` DB), records in two DNS zones, the Grafana org via its service account | Postgres superuser (`.pgpass`), `nlucas` SSH/GitHub keys, other containers, sudo/root, other DNS settings |

## Known residual risk

- `libvirt` group membership controls **every** domain on the host (including `Splunk`), not
  just `k3s-*`. Scoping it needs libvirt's polkit access driver with per-domain rules; deferred.
- The runner currently shares credentials with `nlucas`'s Terraform setup. Issuing it dedicated
  tokens gives independent revocation; tracked as a follow-up.

## Amendment 2026-11-05: RestrictSUIDSGID removed

`RestrictSUIDSGID=yes` made the runner fail to unpack actions: tar returned ENOSYS on open/mkdir. A test that dropped one hardening option at a time showed it was the only cause. It was removed. The remaining risk is small: `NoNewPrivileges=yes` stops anything the runner executes from gaining privileges, and `/var/lib/gh-runner` is mode 700, so no other user can reach a setuid file created there.
