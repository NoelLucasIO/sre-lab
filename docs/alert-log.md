# Alert log

Every alert that reached a human (or should have), and whether it needed action. Feeds the alert-tuning week (2026-11-09 to ~11-16): an alert that fires without needing action gets removed, downgraded or retuned. Times ET. Runbooks: [`docs/runbooks/`](runbooks/README.md).

| When | Alert | Sev | Cause | Action needed? | Note |
|---|---|---|---|---|---|
| 11-09 10:14 | `NightscoutCGMFreshnessBudgetBurn` | ticket | Cold start of the SLO rules plus an upstream blip | No | |
| 11-09 11:55 | `NightscoutCGMFreshnessBudgetBurn` | ticket | Upstream blip, both instances | No | |
| 11-09 13:39 | `NightscoutCGMFreshnessBudgetBurn` | ticket | Upstream blip ~13:30 (copy 2 min, live 4 min stale) | No | Dashboard showed 6% budget left: the 28-day ratio is computed over ~22 h of history |
| 11-09 15:10 | `NightscoutCGMFreshnessBudgetBurn` | ticket | Upstream blip 15:09, both instances 2 min | No | |
| 11-09 19:10 | `NightscoutCGMFreshnessBudgetBurn` | ticket | Upstream blip 19:09, both instances 2 min | No | PD #9, auto-resolved 21:10. 15:09 and 19:09 are exactly 4 h apart: watch for a pattern |
| 11-10 00:21 | healthchecks.io "sre-lab Watchdog is DOWN" | page | fedora NIC hang, no network 00:11:56 – 08:53 | **Yes** | PD #10, acked 00:23, resolved by healthchecks.io 08:53. [Postmortem](postmortems/2026-11-10-fedora-nic-hang.md). The only alert that could leave fedora |
| 11-10 00:16 – 01:04 | CGM freshness ticket + page, tconnectsync page + ticket, `UpstreamCGMStale` | page / ticket | Same outage | (Yes) | Not deliverable until 08:53. `UpstreamCGMStale` misclassified the outage as upstream and inhibited the freshness page: fixed (egress check) |
| 11-10 02:57 | `PumpDataStale` | ticket | Same outage | (Yes) | Not deliverable |
| 11-10 08:53 / 08:54 | `TconnectsyncPollFailureBudgetBurn`, `NightscoutCGMFreshnessBudgetBurn` | page | Still firing after recovery | No | PD #11, #12, acked 08:55, auto-resolved 09:23 / 09:24. Late delivery; the outage was already over |
| 11-10 09:23 / 09:24 | `TconnectsyncPollFailureBudgetBurn`, `NightscoutCGMFreshnessBudgetBurn` | ticket | Pages resolved, so their tickets were no longer inhibited; 6 h & 3 d windows still held the outage | No | PD #13, #14, resolved by hand 09:44. The alerts kept firing until the 6 h windows emptied (~15:00, ~16:30); `repeat_interval` 24 h, so no re-open |
| 11-10 10:00 | `TconnectsyncPollFailureBudgetBurn` | page | Planned reboot (kernel update) restarted tconnectsync; restarts count as failures | No | PD #15, resolved 10:01 and again 10:27. Tuning: should a planned restart page? |
| 11-10 11:06 | `NightscoutCGMFreshnessBudgetBurn` | page | 2-min upstream blip 11:04; the 30 m & 6 h condition still held the night's outage | No | PD #16, resolved 11:06. Tuning: residual pages after a large burn |

## Running tally (for the end-of-week decision)

- **Upstream blips after cold start:** 4 tickets on 11-09 (11:55, 13:39, 15:10, 19:10), none needing action. If this continues after the windows hold a clean week, revisit the 10-minute freshness threshold or the ticket windows.
- **Pages needing no action:** 3 on 11-10 (08:53 late delivery, 10:00 planned reboot, 11:06 residual burn). Tickets needing no action: 2 more on 11-10 (09:23 / 09:24, the outage's tail).
