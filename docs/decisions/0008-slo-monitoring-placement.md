# ADR 0008: SLO monitoring runs outside the cluster, on fedora's Prometheus

**Status:** Accepted, 2026-11-08

## Context

Phase 3 puts SLOs and burn-rate alerts on the Nightscout copy in k3s (ADR 0007): data freshness, API availability and tconnectsync sync latency. The first choice is where the Prometheus that evaluates them runs.

State of fedora's monitoring on 2026-11-08:

- Prometheus 3.16.0, rootless quadlet, host network, `:9091`, 365-day retention, `--web.enable-lifecycle`. Config is hand-maintained in `/990/prometheus/config` and scrapes the network, Podman, akvorado and node targets.
- No rule groups and no Alertmanager.
- fedora reaches the copy through Traefik on all three nodes (`/` → 200, < 10 ms). `/api/v1/*` → 401 without `api-secret`, as designed.
- Nightscout exposes no Prometheus metrics. The k3s nodes run no node_exporter.

## Decision

- **The existing fedora Prometheus evaluates the SLOs.** No Prometheus runs in the cluster.
  - The monitor must outlive the thing it monitors. Phase 4 kills a k3s node on purpose; an in-cluster Prometheus can go down with it and lose the very burn-rate data the game day is meant to produce.
  - Availability is probed from outside the cluster (Blackbox Exporter on fedora → Traefik → Ingress → Service → Pod), so the SLI measures the path a client actually takes.
  - One Prometheus sees both the copy and the live instance (`ns.noellucas.io`). When both go stale together the cause is upstream (sensor, phone, Dexcom Share), not a release; this addresses the coupling noted in ADR 0007.
  - The nodes have 8 GiB each; a full in-cluster stack would compete with the workload for little gain at this size.
- **The repo owns only its own files on fedora, not the whole Prometheus config.** The hand-maintained `prometheus.yml` gains two lines that include repo-managed fragments:
  - `rule_files:` → the generated SLO recording and alerting rules (Sloth/Pyrra output, committed).
  - `scrape_config_files:` → the scrape jobs for the copy, the live instance and the Blackbox probes.
  Unrelated jobs (akvorado, SNMP, OPNsense, node) stay as they are.
- **Alertmanager is added as a new quadlet on fedora**, defined in the repo, and routes to PagerDuty.
- **App-level SLIs come from a small exporter inside the `nightscout` namespace.** It reads the newest CGM entry and the newest tconnectsync upload through the authenticated API and serves them as gauges; fedora scrapes it through the Ingress. The API secret stays in the k3s Secret and never reaches Prometheus.

## Consequences

- No Kubernetes-native discovery (ServiceMonitor, PodMonitor) and no pod- or container-level metrics for now. If those are needed, kube-state-metrics can run in the cluster and be scraped from fedora as one more fragment.
- fedora is a single point of failure for monitoring. Accepted for a lab; nothing watches the watcher yet. A dead-man's-switch alert (always-firing `Watchdog` → PagerDuty heartbeat or equivalent) is the cheapest mitigation and is on the Phase 3 list.
- The repo's fragments must reach `/990/prometheus/config`, which `gh-runner` cannot write (ADR 0005). Delivery (CI with a narrow writable directory vs. a manual sync by Noel) is decided when the fragments exist.
- The Prometheus image stays `:latest` with `AutoUpdate=registry`, by choice: monitoring infrastructure tracks upstream, while app images stay digest-pinned because they are what the pipeline deploys and rolls back. The cost is that an upstream release can change rule evaluation without a PR, so the repo's rules are checked in CI with `promtool check rules` and `promtool test rules`, and a failed rule evaluation (`prometheus_rule_evaluation_failures_total`) alerts.
