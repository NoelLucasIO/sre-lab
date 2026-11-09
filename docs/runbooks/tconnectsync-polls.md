# tconnectsync polls (and pump data staleness)

**Alerts:** `TconnectsyncPollFailureBudgetBurn` (page, ticket), `PumpDataStale` (ticket)
**SLO:** 99% of Tandem Source polls by the copy's tconnectsync succeed; a container restart counts as a failure.
**Impact:** pump data (basal, boluses, suspends) stops reaching Nightscout. Glucose is unaffected (it comes from Dexcom Share).

## 1. What is tconnectsync saying?

```bash
pq 'sum by (result) (increase(tconnectsync_polls_total{instance="k3s-copy"}[1h]))'
pq 'tconnectsync_container_restarts'
KC logs deploy/tconnectsync --since=1h | grep -E 'Error during autoupdate poll|ApiLoginException|Traceback|Sleeping' | tail -20
```

Each poll ends in exactly one line: `Sleeping for … sec` (success), `Sleeping N seconds after unexpected no index change` (success, no new data) or `Error during autoupdate poll (N consecutive)` (failure).

## 2. Is live failing the same way?

```bash
podman logs --since 1h nightscout-tconnectsync 2>&1 | grep -E 'Error during autoupdate poll|ApiLoginException|Sleeping' | tail -10
```

Both failing → Tandem's side or the shared credentials. Only the copy → the copy.

## 3. Causes

| Symptom | Cause | Action |
|---|---|---|
| `ApiLoginException`, container restarting | Tandem password changed or account locked | Update Podman secret `ns-tandem-pass` (live: `systemctl --user restart nightscout-tconnectsync`), then Noel re-runs `ci/nightscout/seed-secret.sh` for the copy. Do not let it crash-loop for long: every restart is a fresh login. |
| `HTTP 5xx`, `ConnectionError`, `Timeout`, on both | Tandem Source outage | Nothing to fix here. tconnectsync backs off (30 s up to 5 min) and exits after 45 min of failures (`AUTOUPDATE_API_FAILURE_MINUTES`) so Kubernetes restarts it. Check Tandem Source in a browser. |
| Errors only on the copy | the copy's network/DNS or its Secret | Read the exact error in `KC logs deploy/tconnectsync --since=1h`. DNS or connection errors point at the cluster (`ssh nlucas@192.168.2.40 sudo k3s kubectl -n kube-system get pods`); 401s at the Secret: Noel re-runs `ci/nightscout/seed-secret.sh`. (The deployer cannot `exec` into pods.) |
| Pod Pending / not scheduled | cluster capacity or node down | `ssh nlucas@192.168.2.40 sudo k3s kubectl get nodes` |

## PumpDataStale (no pump event for 3 hours)

Polls can succeed with nothing new to fetch. Before treating it as a fault:
1. Is the pump uploading? The phone app (t:slim / Mobi) must be paired, running and online; Tandem Source in a browser shows the last upload.
2. Pump suspended, disconnected or between cartridges: no events is correct.
3. Live stale too (`pq '(time() - nightscout_newest_pump_event_timestamp_seconds) / 3600'`)? Then it is upstream.
4. Only the copy stale while its polls succeed: check the log for `Found events` with zero uploads, and `KC logs deploy/tconnectsync | grep -i nightscout` for upload errors.

## Confirm recovery

New `Sleeping for 300.0 sec` lines with no errors; `pq 'sum by (result) (increase(tconnectsync_polls_total{instance="k3s-copy"}[15m]))'` shows only `success`.
