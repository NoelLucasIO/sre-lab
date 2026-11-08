# Service level objectives: Nightscout on k3s

Measured service: the Nightscout copy in namespace `nightscout` (ADR 0007), evaluated by fedora's Prometheus (ADR 0008). Error budgets are computed over a rolling **28 days**. Burn-rate alerts follow the multi-window, multi-burn-rate pattern: fast burn pages, slow burn opens a ticket.

| SLO | SLI (good / valid) | Target | Fast burn | Status |
|---|---|---|---|---|
| CGM data freshness | 5-minute windows in which the newest CGM entry is < 10 min old / all windows | 99% | page | provisional: validate against history |
| API availability | successful authenticated API probes through the Ingress / all probes | 99.5% | page | probe mechanism to be decided |
| tconnectsync poll success | successful Tandem Source polls / all polls | 99% | page | defined |
| Pump data latency | pump events stored ≤ T after they happened / all pump events | 99% at T to be set from data | ticket only | baseline measured; T after 1 week |

## Why sync latency became two SLOs

The lab plan specified "tconnectsync pulls succeed within 15 minutes, 99% of the time". Measurement showed that target cannot be met by anything under our control.

**Baseline** (live instance, 1,184 tconnectsync treatments, 2026-11-04 → 2026-11-08; latency = `srvCreated` − `created_at`):

| min | p50 | p90 | p99 | max | ≤ 15 min |
|---|---|---|---|---|---|
| 3.3 min | 44.3 min | 69.3 min | 82.7 min | 683.9 min | 6.4% |

Events arrive in 96 batches (median 12 events each) 50 or 75 minutes apart. Two causes, from tconnectsync v3.0.3's logs and source:

1. **Upstream, not ours.** The pump uploads to Tandem Source through the phone app roughly hourly; at one poll the newest Tandem Source data was already 38 minutes old.
2. **Ours.** In `--auto-update` mode tconnectsync waits the average observed interval between Tandem Source updates, capped at `AUTOUPDATE_MAX_SLEEP_SECONDS` (1500 s). Hourly upstream updates always hit the cap, so polls run every 25 minutes and add 0-25 minutes of wait.

So the SLOs are split by who can act:

- **tconnectsync poll success** covers the part we run. A poll is good when tconnectsync logs `Found events` or `No new reported tandemsource data`, and bad when it logs `ApiException` or an error. Counted from the pod's logs by the exporter, under its own ServiceAccount limited to `get pods/log` in `nightscout`. Pages, because an operator can act (credentials, Tandem API changes, a crashed pod).
- **Pump data latency** covers what a user experiences end to end. Ticket only: most of it is upstream, and paging someone for Tandem's upload schedule is alert fatigue by design.
- A **staleness guard** (newest tconnectsync event age) catches the case the latency SLI cannot: no events at all looks like no latency.

## Experiment: fixed 5-minute polling on the copy

The copy runs `AUTOUPDATE_USE_FIXED_SLEEP=true`, `AUTOUPDATE_DEFAULT_SLEEP_SECONDS=300`; the live instance keeps the default. Expected: median latency down by roughly 10 minutes, at about 5× the Tandem Source API calls. After one week, compare the copy's latency distribution with the live instance's, then set T and decide whether to apply the change to the live instance.

## Known limits

- CGM freshness depends on the sensor, the phone and Dexcom Share. An upstream outage burns the freshness budget even though nothing we run failed. Because Prometheus watches the live instance too, alerts and runbooks can tell the cases apart: both stale → upstream, only the copy stale → us.
- Single replicas on `local-path` storage; the error budget is consumed by node maintenance as well as by failures.
