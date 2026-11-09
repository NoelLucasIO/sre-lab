# CGM freshness

**Alerts:** `NightscoutCGMFreshnessBudgetBurn` (page, ticket), `UpstreamCGMStale` (info)
**SLO:** 99% of time (28 days) the newest CGM reading on the k3s copy is under 10 minutes old.
**Impact:** glucose on the copy is out of date. If live is also stale, anyone watching Nightscout is blind to current glucose.

## 1. Upstream or us? (one query)

```bash
pq 'nightscout:entry_stale:bool'                     # 1 = stale, per instance
pq '(time() - nightscout_newest_entry_timestamp_seconds) / 60'   # minutes since newest reading
```

| copy | live | Meaning | Go to |
|---|---|---|---|
| 1 | 1 | Upstream: sensor, phone/receiver, or Dexcom Share | 2 |
| 1 | 0 | Ours: the k3s copy | 3 |
| 0 | 1 | The live pod only (not this SLO, but fix it) | 4 |

`UpstreamCGMStale` firing is the same as row 1.

## 2. Upstream (both stale)

1. **Sensor change?** A new sensor warms up for about 30 minutes; a change costs about 55 minutes of readings. If a sensor was started within the last hour or so: **expected, no action.** Note it in the incident log; it spends budget by design (about 2.75 h of the 6.7 h 28-day budget at 3 changes a month).
2. **Phone or receiver:** the Dexcom app must be running, signed in, with Share on and the phone online.
3. **Dexcom Share itself:** if the Dexcom app shows current readings but both instances are stale for more than 30 minutes, the Share service or the bridge login is failing. Check the bridge log on live:
   ```bash
   podman logs --since 30m nightscout 2>&1 | grep -iE 'bridge|share|dexcom|error' | tail -20
   ```
   A login error means the Dexcom password changed: update Podman secret `ns-bridge-pass`, then `systemctl --user restart nightscout`, then re-run `ci/nightscout/seed-secret.sh` so the copy gets it too.

## 3. Only the copy is stale (ours)

```bash
KC get pods -o wide
KC logs deploy/nightscout --since=30m | grep -iE 'bridge|error|mongo' | tail -20
KC get events --sort-by=.lastTimestamp | tail -15
```

- **A recent deploy?** Check the `nightscout` workflow runs on GitHub. A deploy that failed its health check has already been rolled back automatically (an issue labelled `deploy-failure` says so). If a deploy went green but readings stopped after it: `KC rollout undo deployment/nightscout`, then revert the PR on `main`.
- **Pod not Running / CrashLoopBackOff:** read `KC logs deploy/nightscout --previous`. MongoDB not ready (`KC get pods -l app=mongo`) stops Nightscout from storing readings.
- **Bridge errors only on the copy:** the copy's Secret is out of date. Noel re-runs `ci/nightscout/seed-secret.sh` on fedora.
- **Node trouble** (pods Pending, node NotReady): `ssh nlucas@192.168.2.40 sudo k3s kubectl get nodes`.

## 4. Only live is stale

```bash
systemctl --user status nightscout-pod nightscout nightscout-mongo --no-pager | grep -E 'Active|●'
podman logs --since 30m nightscout 2>&1 | tail -30
systemctl --user restart nightscout     # if the container is up but not storing readings
```

## Confirm recovery

`pq 'nightscout:entry_stale:bool'` is 0 for both, and the newest reading is under 5 minutes old. The page clears on its own once the 5-minute error ratio drops.
