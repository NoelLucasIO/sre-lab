# API availability

**Alert:** `NightscoutAPIAvailabilityBudgetBurn` (page, ticket)
**SLO:** 99.5% of Blackbox probes succeed: authenticated `GET /api/v1/status.json` through each k3s node's Traefik ingress, answering 2xx with `"status":"ok"`.
**Impact:** clients of the copy (dashboards, apps, uploaders) get errors or nothing.

## 1. Which nodes, what answer?

```bash
pq 'probe_success{job="blackbox-ns-copy"}'            # per node
pq 'probe_http_status_code{job="blackbox-ns-copy"}'    # 0 = no HTTP answer at all
pq 'probe_success{job="blackbox-ns-live"}'             # is live affected too?
```

Reproduce one probe by hand (prints the same result Prometheus sees):

```bash
curl -s '127.0.0.1:9115/probe?module=ns_copy&target=http://192.168.2.40/api/v1/status.json&debug=true' | tail -30
```

## 2. Read the answer

| Failing | Status | Likely cause | Action |
|---|---|---|---|
| one node | 0 | that node or its Traefik is down | `ssh nlucas@192.168.2.40 sudo k3s kubectl get nodes`; `... -n kube-system get pods -o wide \| grep traefik` |
| all nodes | 401 | the copy's API secret changed, so the probe's header is wrong | recreate Podman secret `ns-k3s-api-hash` (below), then `systemctl --user restart blackbox` |
| all nodes | 404 | Ingress missing or host rule changed | `KC get ingress`; compare with `k8s/nightscout/nightscout.yaml` |
| all nodes | 502/503/0 | Nightscout pod not ready | `KC get pods`; `KC logs deploy/nightscout --since=15m`; see below |
| all nodes | 200, still failing | body lacks `"status":"ok"` | the debug output above shows the body |

**Nightscout pod not ready:**
```bash
KC get pods -l app=nightscout -o wide
KC describe pod -l app=nightscout | tail -25
KC logs deploy/nightscout --previous | tail -30
```
If it started after a deploy: `KC rollout undo deployment/nightscout` and revert the PR. If MongoDB is down (`KC get pods -l app=mongo`), Nightscout cannot start.

**Recreate the probe's header secret** (sha1 of the copy's API secret; never on a command line):
```bash
podman secret rm ns-k3s-api-hash
KC get secret nightscout-secrets -o jsonpath='{.data.API_SECRET}' | base64 -d | sha1sum | cut -d' ' -f1 \
  | tr -d '\n' | podman secret create ns-k3s-api-hash -
systemctl --user restart blackbox
```
For live, the same with `ns-live-api-hash`, from Podman secret `ns-api-secret`.

## Confirm recovery

`pq 'probe_success{job="blackbox-ns-copy"}'` is 1 on all three nodes for a few minutes.
