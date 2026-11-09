# Pump data latency

**Alert:** `PumpDataLatencyBudgetBurn` (ticket only, never pages)
**SLO:** 99% of pump events reach Nightscout within 90 minutes of happening (provisional threshold; set from data on 2026-11-15).
**Why ticket only:** most of this delay is upstream. The pump uploads to Tandem Source through the phone app about hourly, and Tandem Source itself lags; baseline p50 44 min, p99 83 min (`docs/slos.md`). Paging for Tandem's upload schedule would be noise.

## 1. How late, and is live the same?

```bash
pq 'histogram_quantile(0.5,  sum by (instance, le) (increase(nightscout_pump_event_latency_seconds_bucket[6h]))) / 60'
pq 'histogram_quantile(0.99, sum by (instance, le) (increase(nightscout_pump_event_latency_seconds_bucket[6h]))) / 60'
```

- **Both instances late by a similar amount:** upstream. Check the phone app is uploading (Tandem Source shows the last upload time). Usually no action; note it.
- **Only the copy late:** tconnectsync on the copy is polling slowly or failing. `KC logs deploy/tconnectsync --since=2h | grep -E 'Sleeping|Error'`: expect `Sleeping for 300.0 sec` (fixed 5-min polling). Anything else means its config changed; see `k8s/nightscout/kustomization.yaml` (`tconnectsync-config`). Poll failures: [tconnectsync-polls](tconnectsync-polls.md).
- **Only live late:** live uses the adaptive wait (capped at 25 min), so it is expected to be later than the copy.

## Confirm recovery

The 6-hour p99 drops back under 90 minutes; the ticket clears on the 2 h / 1 d windows.
