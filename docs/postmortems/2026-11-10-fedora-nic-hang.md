# Postmortem: fedora offline for 8 h 41 min (NIC hang), 2026-11-10

**Status:** final · **Severity:** SLO miss (CGM freshness, tconnectsync polls); LAN-wide DNS outage · **Format:** blameless
**Duration:** 00:11:56 – 08:53 ET without network on fedora; CGM data stale 00:14 – 08:54 ET

## Summary

At 00:11:56 ET the onboard Intel I219-LM network card on `fedora` (driver `e1000e`) hit a transmit hang. The kernel logged `Detected Hardware Unit Hang` every 2 seconds, but the driver never reset the adapter, so the hang lasted until the host was power-cycled at 08:50. The OS and every container kept running; fedora just could not transmit.

fedora runs the live Nightscout pod, hosts the k3s nodes as VMs on its bridge, and runs the LAN's only DNS server (Technitium). So one NIC took down both Nightscout instances, both tconnectsyncs, and name resolution for the whole LAN.

The external heartbeat (healthchecks.io) paged within 10 minutes, as designed; nothing else could, because Alertmanager had no route to PagerDuty. The alerting also misread the outage: "both instances stale" is the rule for "upstream, not ours", so `UpstreamCGMStale` fired and inhibited the CGM freshness page. That page could not have been delivered anyway, but the classification was wrong, and this change fixes it.

## Impact

| Area | Effect |
|---|---|
| `cgm-freshness` (99%, 28 d) | Both instances stale 00:14:00 – 08:54:30 (521 min). The 28-day budget is 403 min, so this outage alone is **≈129% of the budget**: the SLO is missed for this window. Sloth reports −32.0 remaining because its 28-day ratio is averaged over the ~2 days of history the rules have so far. |
| `tconnectsync-polls` (99%) | Polls failed 00:15 – 08:53 (Tandem Source unreachable). Sloth: −25.9 remaining (same cold-start caveat). |
| `PumpDataStale` | Ticket condition from 02:57 to 08:54. |
| `api-availability` | Unaffected: the probes run on fedora and never leave it (budget remaining 0.70, unchanged). |
| LAN | No DNS for any client (the P620 could ping the gateway and external IPs but resolve nothing). fedora and everything on it unreachable from the LAN. |
| User-facing | Nightscout showed no new glucose or pump data overnight; anything relying on Nightscout for overnight viewing was blind for 8 h 40 min. |

## Detection and response

| Time | PagerDuty | What it was |
|---|---|---|
| 00:21 | #10 triggered (`sre-lab-nightscout`) | healthchecks.io: "sre-lab Watchdog is DOWN" (last ping ~00:11, 5 min period + 5 min grace) |
| 00:23 / 00:24 | #10 acknowledged (mobile app, SMS) | Noel |
| 08:53 | #10 resolved by healthchecks.io | Pings resume after the power-cycle |
| 08:53 / 08:54 | #11 tconnectsync page, #12 CGM freshness page | Still firing at recovery; delivered as soon as egress returned |
| 08:55 | #11, #12 acknowledged | Noel |
| 09:23 / 09:24 | #11, #12 auto-resolved; #13, #14 tickets triggered (`sre-lab-tickets`) | The pages' short windows cleared; the inhibit "a page drops its own ticket" lifted, as designed |
| 09:44 | #13, #14 resolved | Noel (the underlying alerts kept firing until the 6-hour windows emptied, ~15:00 and ~16:30) |

Prometheus kept evaluating throughout (it runs on fedora and the scrapes it needs are local), so every burn-rate alert fired on time: CGM freshness ticket 00:16 and page 00:23, tconnectsync page 00:28 and ticket 01:04. None could leave fedora until 08:53.

## Timeline (ET)

| Time | Event |
|---|---|
| 00:11:56 | First `e1000e … Detected Hardware Unit Hang` on `enp0s31f6`. Repeats every 2 s (15,550 times); no adapter reset, no `NETDEV WATCHDOG` timeout, link stays up at 1000/Full. |
| 00:12:30 | First failed metric: OPNsense exporter scrape (`up{job="opnsense"}` = 0). LAN DNS fails with it. |
| 00:14 | Both Nightscout instances stale (newest reading ≥ 10 min old). |
| 00:15 | tconnectsync polls start failing. |
| 00:16 – 00:28 | Freshness ticket and page, tconnectsync page fire in Prometheus; `UpstreamCGMStale` fires and inhibits the freshness page. Nothing can leave fedora. |
| 00:21 | healthchecks.io pages (PagerDuty #10). Acknowledged 00:23. |
| 00:23 – 08:50 | fedora unreachable over the network: no SSH, no remote reset. Recovery waits for a physical power-cycle. |
| 02:57 | `PumpDataStale` fires (no pump event for 3 h). |
| 08:50:14 | Physical power-cycle (Noel). Last hang message. |
| 08:52:47 | fedora boots; quadlets start (Alertmanager, Nightscout pod, exporter). |
| 08:53 | Egress restored; healthchecks.io resolves #10; tconnectsync page delivered (#11). |
| 08:54:30 | Both instances fresh again; CGM freshness page delivered (#12). |
| ~09:00 | Root cause found in the previous boot's journal. |
| ~09:40 | TSO, GSO and EEE turned off on `enp0s31f6`, live (`ethtool`) and persistent (NetworkManager profile `br0-port`). |
| 09:50 – 09:58 | Kernel 7.2.15 → 7.3.3 installed; clean reboot 09:56, up 09:58. |
| 10:00 – 10:28 | `TconnectsyncPollFailureBudgetBurn` pages (#15): the reboot restarted tconnectsync, and restarts count as failures in that SLI. |
| ~09:45 – 12:00 | `nic-watchdog` self-heal timer installed; verified healthy at 12:05. |
| 11:06 | CGM freshness page (#16) from a 2-minute upstream blip at 11:04: the 30 m & 6 h condition still held the night's outage. |

## Root cause

A transmit hang in the Intel I219-LM (`e1000e`, firmware 2.5-4, kernel 7.2.15). The TX ring stopped advancing (`TDH <2f>` behind `TDT <55>`, unchanged for 8.5 hours) and the driver's transmit-timeout reset never triggered. That missing reset is why the outage lasted hours rather than seconds. This is a known I219 failure mode, most often linked to TCP segmentation offload, with Energy-Efficient Ethernet as another known contributor; TSO, GSO and EEE were all on. No scheduled job ran near 00:11. It is the first occurrence on this host (no hang messages in any boot back to 2026-10-27).

## Contributing factors

1. **One failure domain for "two instances".** The live pod runs on fedora and the k3s copy runs in VMs on fedora's bridge, so both share one physical uplink. The SLO design assumed the two instances share only their upstream sources, which made "both stale" look like proof of an upstream cause.
2. **The upstream discriminator had no check on our own connectivity.** `UpstreamCGMStale` = both instances stale for 5 minutes. A local network failure satisfies it, so the outage was classified as Dexcom's.
3. **No self-recovery and no remote recovery.** The driver did not reset itself, and a host that cannot transmit cannot be reached to reset it. Recovery needed someone at the machine.
4. **LAN DNS runs only on fedora.** One NIC failure took name resolution away from every client on the LAN.
5. **The only alert path that survives a fedora network outage is the heartbeat.** By design (ADR 0008 places monitoring on fedora), everything else goes silent.

## What went well

- The dead man's switch worked: paged at 00:21, about 10 minutes after the last ping, through a path independent of fedora, and acknowledged 2 minutes later.
- Prometheus kept a complete local record of the outage, so the impact above is measured, not estimated.
- After recovery, routing behaved as designed: pages first, then tickets once the pages resolved (the "page drops its own ticket" inhibit).
- The root cause came from the journal within minutes of recovery, and hardening plus a self-heal path were in place the same morning.
- The SLO budget math made the cost explicit: one night cost 129% of a month's budget.

## What went wrong

- Our own rule labelled the outage "upstream" and inhibited the freshness page.
- The page was acknowledged at 00:23, but nothing could be done remotely: 8.5 hours from page to recovery, set entirely by the need for physical access.
- Follow-up noise: a planned reboot paged (10:00), and a 2-minute upstream blip paged (11:06) because the 6-hour window still carried the outage.

## Action items

| # | Action | Type | Status |
|---|---|---|---|
| 1 | TSO, GSO and EEE off on `enp0s31f6` (live and persistent in `br0-port`) | Prevent | **Done** ~09:40 |
| 2 | Kernel 7.3.3 | Prevent | **Done** 09:58 |
| 3 | `nic-watchdog` timer: every 30 s, on 3 failed gateway pings plus hang messages (or 10 failures regardless), link bounce, then driver reload, then cooldown | Recover | **Done** (verified 12:05; not yet exercised by a real hang) |
| 4 | Egress probes (two providers, by name) and `lab:egress_up:bool`; `UpstreamCGMStale` requires fedora online | Detect / classify | This PR |
| 5 | `LabEgressDown` ticket with `keep_firing_for: 15m`, so an offline period reaches PagerDuty after recovery as a record | Detect | This PR |
| 6 | Runbook: hung-NIC diagnosis, `nic-watchdog`, and the "nothing can page" caveat (`monitoring.md#labegressdown`) | Respond | This PR |
| 7 | Second DNS resolver handed out by DHCP (for example Unbound on OPNsense) | Mitigate | Open (high) |
| 8 | Alert when `nic-watchdog` acts (journal tag `nic-watchdog`, `ACTION:`), so a self-healed hang is still seen | Detect | Open (medium) |
| 9 | Move `br0` to the AQC113 (`enp1s0`, already cabled) or an active-backup bond with ARP monitoring (`arp_ip_target=192.168.2.1`; MII monitoring would not have caught this, the link stayed up) | Prevent | Open (medium) |
| 10 | Out-of-band reset for fedora (Intel AMT if the platform supports it, or a smart plug or PDU) for hangs the watchdog cannot clear | Recover | Open |
| 11 | Decide whether planned restarts count as tconnectsync failures (10:00 page) | Tune | Open: alert-tuning week |
| 12 | Decide how to handle residual pages from the 6-hour windows after a large burn (11:06 page) | Tune | Open: alert-tuning week |
| 13 | Remove the shared failure domain: run the copy, or a probe of upstream, somewhere fedora's NIC does not carry | Design | Open: later phase |
| 14 | Replace the onboard I219 (add-in i210/i226, or the AQC113 only) if hangs recur with TSO, GSO and EEE off | Prevent | Contingent |

## Evidence

```promql
nightscout:entry_stale:bool                       # 1 from 00:14:00 to 08:54:30 on both instances
up{job="opnsense"}                                # 0 from 00:12:30 to 08:53
ALERTS{alertname="UpstreamCGMStale"}              # firing through the outage (the misclassification)
slo:period_error_budget_remaining:ratio
```

```bash
journalctl -k -b -2 | grep -c 'Detected Hardware Unit Hang'      # 15550 (boot -2 = 2026-11-03 15:29 – 2026-11-10 08:50)
journalctl -k -b -2 | grep -cE 'Reset adapter|NETDEV WATCHDOG'   # 0: the driver never reset
ethtool -k enp0s31f6 | grep -E '^(tcp|generic)-segmentation-offload'   # both off
ethtool --show-eee enp0s31f6 | sed -n 2p                          # disabled
journalctl -t nic-watchdog                                        # empty = never needed to act
```
