# Runbooks

One runbook per alert area; every alert's `runbook_url` points here. Written for someone who did not build the system. SLO definitions and the data behind them: [`docs/slos.md`](../slos.md).

| Alert | Severity | Runbook |
|---|---|---|
| `NightscoutCGMFreshnessBudgetBurn` | page / ticket | [cgm-freshness](cgm-freshness.md) |
| `UpstreamCGMStale` | info | [cgm-freshness](cgm-freshness.md) |
| `NightscoutAPIAvailabilityBudgetBurn` | page / ticket | [api-availability](api-availability.md) |
| `TconnectsyncPollFailureBudgetBurn` | page / ticket | [tconnectsync-polls](tconnectsync-polls.md) |
| `PumpDataStale` | ticket | [tconnectsync-polls](tconnectsync-polls.md) |
| `PumpDataLatencyBudgetBurn` | ticket | [pump-data-latency](pump-data-latency.md) |
| `LabEgressDown` | ticket | [monitoring](monitoring.md#labegressdown) |
| `NightscoutExporterDown`, `BlackboxProbesMissing`, `PrometheusRuleEvaluationFailures`, `Watchdog` | ticket / none | [monitoring](monitoring.md) |
| healthchecks.io "sre-lab backup dump", "sre-lab backup offsite", "sre-lab restore test" | ticket | [backups](backups.md) |
| Drift check: "ci/runner/known_hosts differs"; SSH "REMOTE HOST IDENTIFICATION HAS CHANGED" | (CI failure) | [host-keys](host-keys.md) |

**Page** = act now (the 28-day error budget is burning at 13.44× or faster): PagerDuty service `sre-lab-nightscout`, high urgency. **Ticket** = act within a working day: PagerDuty service `sre-lab-tickets`, urgency fixed Low (email, no call).

## The system in one paragraph

Two Nightscout instances read the same Dexcom Share and Tandem Source accounts. **live** is a rootless Podman pod on `fedora` (192.168.2.45, user `nlucas`, quadlets in `~/.config/containers/systemd/`). **k3s-copy** runs in namespace `nightscout` on the k3s cluster (nodes .40, .41, .42) and is the service these SLOs cover. Prometheus on fedora (`:9091`) scrapes an SLI exporter for each instance and Blackbox probes of each instance's API. Because both instances share their upstream sources, **"both stale" means upstream; "only the copy" means us**, with one exception: both instances also share fedora's network uplink (the k3s nodes are VMs on fedora), so "both stale" while fedora is offline is ours (`pq 'lab:egress_up:bool'` is 0).

## Shared commands (on fedora, as `nlucas`)

```bash
# kubectl as the namespace-scoped deployer (can read pods/logs/events, roll back workloads)
KC() { sudo -u gh-runner /var/lib/gh-runner/.local/kubectl/kubectl \
  --kubeconfig /var/lib/gh-runner/.kube/nightscout-deployer.yaml -n nightscout "$@"; }

# PromQL from the shell
pq() { curl -s --get localhost:9091/api/v1/query --data-urlencode "query=$1" \
  | python3 -c 'import json,sys; [print(r["metric"], r["value"][1]) for r in json.load(sys.stdin)["data"]["result"]]'; }

# Error budget left for each SLO (1 = untouched, 0 = spent, negative = SLO missed)
pq 'slo:period_error_budget_remaining:ratio'

# Cluster-admin view (nodes, other namespaces): over SSH to the k3s server
ssh -o UserKnownHostsFile=~/sre-lab/ci/runner/known_hosts nlucas@192.168.2.40 sudo k3s kubectl get nodes -o wide
```

**Host keys for the SSH line:** the nodes' host keys are managed by Terraform and survive rebuilds ([ADR 0011](../decisions/0011-managed-host-keys.md)); `ci/runner/known_hosts` pins them, so point SSH at it as above rather than accepting a key. If SSH reports a changed host key, see [host-keys](host-keys.md).

Grafana (`fedora:3001`) Explore works for every query here too.

## After any incident

Note what fired, when, what you did and whether the alert needed action in [`docs/alert-log.md`](../alert-log.md). That log feeds the alert-tuning week: an alert that fired without needing action gets removed or downgraded. Outages get a blameless postmortem in [`docs/postmortems/`](../postmortems/).
