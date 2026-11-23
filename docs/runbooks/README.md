# Runbooks

One runbook per alert area; every alert's `runbook_url` points here. Written for someone who did not build the system.

| Alert | Severity | Runbook |
|---|---|---|
| `LabEgressDown` | ticket | [monitoring](monitoring.md#labegressdown) |
| `BlackboxProbesMissing`, `PrometheusRuleEvaluationFailures`, `Watchdog` | ticket / none | [monitoring](monitoring.md) |
| Drift check: "ci/runner/known_hosts differs"; SSH "REMOTE HOST IDENTIFICATION HAS CHANGED" | (CI failure) | [host-keys](host-keys.md) |

**Page** = act now: PagerDuty page service (still named `sre-lab-nightscout`), high urgency. **Ticket** = act within a working day: PagerDuty service `sre-lab-tickets`, urgency fixed Low (email, no call).

The Nightscout SLOs, their alerts and runbooks (cgm-freshness, api-availability, tconnectsync-polls, pump-data-latency, backups) were retired on 2026-11-23; they are in git history.

## Shared commands (on fedora, as `nlucas`)

```bash
# PromQL from the shell
pq() { curl -s --get localhost:9091/api/v1/query --data-urlencode "query=$1" \
  | python3 -c 'import json,sys; [print(r["metric"], r["value"][1]) for r in json.load(sys.stdin)["data"]["result"]]'; }

# Cluster-admin view (nodes, namespaces): over SSH to the k3s server
ssh -o UserKnownHostsFile=~/sre-lab/ci/runner/known_hosts nlucas@192.168.2.40 sudo k3s kubectl get nodes -o wide
```

**Host keys for the SSH line:** the nodes' host keys are managed by Terraform and survive rebuilds ([ADR 0011](../decisions/0011-managed-host-keys.md)); `ci/runner/known_hosts` pins them, so point SSH at it as above rather than accepting a key. If SSH reports a changed host key, see [host-keys](host-keys.md).

Grafana (`fedora:3001`) Explore works for every query here too.

## After any incident

Note what fired, when, what you did and whether the alert needed action in [`docs/alert-log.md`](../alert-log.md). An alert that fired without needing action gets removed or downgraded. Outages get a blameless postmortem in [`docs/postmortems/`](../postmortems/).
