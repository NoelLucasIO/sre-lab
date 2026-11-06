# ADR 0007: Nightscout on k3s, with automatic rollback

**Status:** Accepted, 2026-11-06

## Context

Phase 2 needs an application pipeline that can undo a bad release with no one at the keyboard. The service is Nightscout, which runs today as a rootless Podman pod on fedora (quadlets, `ns.noellucas.io`): Nightscout 15.0.9, MongoDB 4.4, tconnectsync. Glucose readings arrive through Nightscout's own Dexcom Share bridge; tconnectsync adds pump data from Tandem Source.

## Decision

- **A full copy runs alongside the live pod**, in namespace `nightscout` on k3s, with its own MongoDB and its own API secret. It reads the same Dexcom Share and Tandem Source accounts, so its data is real and current, but breaking it on purpose (rollback tests, Phase 4 game days) never touches the live service. Trade-off accepted: Tandem Source and Dexcom Share are each polled twice.
- **Images are pinned as `name:tag@sha256:digest`**, enforced by `ci/nightscout/check-images.sh` on every PR. The pins reproduce exactly what the live pod runs (Nightscout 15.0.9 `28ec…`, tconnectsync v3.0.3 `5d18…`), so "the previous version" is always a specific, pullable artifact.
- **MongoDB 7.0.45 in the copy.** Nightscout 15.0.9's driver (`mongodb ^5.9`) is fully compatible with server 7.0 and only partially with 8.0 (MongoDB's driver compatibility table). 5.0+ needs AVX; the VMs use `host-passthrough` and expose it.
- **Platform vs. app split.** Ansible (`ansible/cluster-access.yml`) owns the namespace, Pod Security labels and a `deployer` ServiceAccount whose Role covers only this namespace's workloads and reads exactly one Secret. The app pipeline holds only that account's kubeconfig. The k3s workflow proves the scope with `kubectl auth can-i` in both directions.
- **Secrets never pass through CI or the repo.** `ci/nightscout/seed-secret.sh`, run once by Noel on fedora, copies the Dexcom/Tandem logins from the live pod's Podman secrets to the k3s Secret over SSH stdin.
- **Deploy = apply → rollout status → health check.** Healthy means the authenticated API answers and the newest CGM reading is under 10 minutes old. On any failure, `ci/nightscout/deploy.sh` runs `rollout undo` on every workload whose generation the apply changed, waits for it, health-checks the restored version, opens an issue and fails the job. `maxUnavailable: 0` keeps the old pod serving during a bad rollout; `progressDeadlineSeconds: 180` makes a stuck rollout fail fast.
- **Hash-suffixed ConfigMaps**, so a config change rolls the pods and `rollout undo` restores the old config with the old image.

## Consequences

- The deploy logic lives in scripts, tested against a fake `kubectl` and `curl` under `bash -e -o pipefail` (19 cases, every failure path), and the suite was itself checked by breaking the scripts on purpose (5 mutations, all caught).
- After a rollback, `main` still holds the failed change; the issue says to revert it. A later unrelated deploy would re-apply it.
- The freshness check couples deploy health to upstream data: if the sensor or phone stops uploading, a good release fails its check. `deploy.sh` exits 2 when the restored version is also unhealthy, which points at upstream rather than the change. Phase 3 can compare against the live instance to tell the two apart.
- Single replicas on `local-path` storage: MongoDB is pinned to one node. Acceptable for a copy; Phase 4's DR drill exercises restore.
- Not yet: k3s secrets encryption at rest (`secrets-encryption`), progressive delivery (canary), a DNS record for `ns-k3s` (the health check targets Traefik with `--resolve`).

## Result, 2026-11-06

- First deploy: MongoDB 7.0.45, Nightscout 15.0.9 and tconnectsync v3.0.3 rolled out; health check passed with a live CGM reading.
- Deliberately broken release: same tag, nonexistent digest. It passed every static gate (render, digest policy, server-side dry-run), which is the point: only the post-deploy check can catch it. After approval, with no further input: the new pod could not pull its image, the old pod kept serving (`maxUnavailable: 0`), the rollout hit its 180 s progress deadline, `deploy.sh` ran `rollout undo deployment/nightscout`, the restored version passed the health check, and issue #12 (`deploy-failure`) was opened. The revert PR then brought `main` back in line with the cluster.
