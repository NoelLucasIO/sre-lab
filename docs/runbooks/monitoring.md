# Monitoring itself

**Alerts:** `BlackboxProbesMissing`, `LabEgressDown`, `PrometheusRuleEvaluationFailures` (ticket), `Watchdog` (always firing)
**Why they matter:** when a signal disappears, nothing turns red, it goes silent. These alerts make "blind" visible.

## BlackboxProbesMissing

```bash
systemctl --user status blackbox --no-pager | grep Active
podman logs --tail 30 blackbox
curl -s '127.0.0.1:9115/probe?module=egress&target=https://www.google.com/generate_204' | grep probe_success
```

Config: `/990/blackbox/blackbox.yml` (repo: `prometheus/blackbox.yml`).

## LabEgressDown

fedora could not reach the internet: neither egress probe (Cloudflare, Google, by host name) answered for 5 minutes. While that lasts, **nothing can page**: Alertmanager cannot reach PagerDuty, so healthchecks.io pages instead (the heartbeat stops). This ticket arrives after recovery (it keeps firing for 15 minutes) as the record.

On fedora's console (the network is down, so SSH from elsewhere will not work):

```bash
pq 'probe_success{job="blackbox-egress"}'                      # 0 for both = offline
ip -br link show enp0s31f6; ping -c2 -W1 192.168.2.1; ping -c2 -W2 1.1.1.1; getent hosts www.google.com
journalctl -k --since -2h | grep -E 'e1000e.*(Hang|Reset|Link)' | tail -5
```

- **`e1000e … Detected Hardware Unit Hang`, repeating every 2 s:** the onboard Intel I219-LM has stopped transmitting and the driver is not resetting it ([postmortem 2026-11-10](../postmortems/2026-11-10-fedora-nic-hang.md)). The `nic-watchdog` timer should already be acting (link bounce, then driver reload): `journalctl -t nic-watchdog`, `cat /run/nic-watchdog/{fails,stage}`. If it has escalated without effect, power-cycle (on 2026-11-10 that was the only fix). Prevention is in place: TSO, GSO and EEE off in NetworkManager profile `br0-port`; confirm with `ethtool -k enp0s31f6 | grep -E '^(tcp|generic)-segmentation-offload'` (both `off`) and `ethtool --show-eee enp0s31f6 | sed -n 2p` (disabled). A hang with these off means the NIC needs replacing (postmortem item 14).
- **LAN clients cannot resolve names either:** expected while fedora is offline: Technitium (the LAN's DNS) runs on fedora.
- **Gateway answers, 1.1.1.1 does not:** OPNsense WAN or the ISP. Check from another host too.
- **1.1.1.1 answers, names do not resolve:** DNS (Technitium).

After recovery: log it in [`docs/alert-log.md`](../alert-log.md).

## PrometheusRuleEvaluationFailures

Prometheus auto-updates (`:latest`, ADR 0008); a new release can break a rule.

```bash
curl -s localhost:9091/api/v1/rules | python3 -c 'import json,sys
for g in json.load(sys.stdin)["data"]["groups"]:
    for r in g["rules"]:
        if r.get("health")!="ok": print(g["name"], r.get("name"), r.get("lastError"))'
podman exec prometheus prometheus --version | head -1      # the version fedora runs now
```

Fix the rule in the repo (`prometheus/rules/inputs.yml`), bump `PROMETHEUS_IMAGE` in `.github/workflows/rules.yml` to the version fedora now runs so CI tests it, merge, copy the files to `/990/prometheus/config/sre-lab/rules/`, then `podman exec prometheus promtool check config /etc/prometheus/prometheus.yml && ~/reload-prometheus.sh`.

## Watchdog and the heartbeat (healthchecks.io)

`Watchdog` always fires, by design. Alertmanager sends it to healthchecks.io (check **sre-lab Watchdog**) every minute; healthchecks.io alerts (PagerDuty, through a separate integration key, and email) when no ping arrives for 5 min + 5 min grace. That alert means the **whole monitoring path is down**, so nothing else will page you: start at the bottom.

1. Is fedora up and online? (`ping 192.168.2.45`; OPNsense; power; a hung NIC: see [LabEgressDown](#labegressdown))
2. `systemctl --user status prometheus alertmanager --no-pager | grep Active`
3. Is Prometheus sending to Alertmanager? `curl -s localhost:9091/api/v1/alertmanagers` lists `127.0.0.1:9095`.
4. Is the webhook failing? `curl -s 127.0.0.1:9095/metrics | grep 'alertmanager_notifications_failed_total{integration="webhook"'`; `podman logs --tail 30 alertmanager`.
5. Ping URL secret wrong or rotated: recreate Podman secret `healthchecks-watchdog-url` (same `read -rs` pattern as the PagerDuty key), then `systemctl --user restart alertmanager`.

## Rule and fragment files on fedora

Configs are mounted as **directories**, so a reload sees a replaced file. (A single-file bind mount keeps the old inode: the reload returns 200 and changes nothing.) The directory must be readable by the container's user (`chmod 755`): Blackbox and Alertmanager run as `nobody`, and a `700` directory fails with `permission denied` on start.


| Repo | fedora |
|---|---|
| `prometheus/rules/inputs.yml` | `/990/prometheus/config/sre-lab/rules/…` (via `rule_files` in `prometheus.yml`) |
| `prometheus/scrape/*.yml` | `/990/prometheus/config/sre-lab/scrape/` (via `scrape_config_files`) |
| `prometheus/blackbox.yml` | `/990/blackbox/blackbox.yml` (directory mounted) |
| `prometheus/alertmanager.yml` | `/990/alertmanager/config/alertmanager.yml` (directory mounted); apply with `curl -X POST 127.0.0.1:9095/-/reload` |
| `prometheus/*.container` | `~/.config/containers/systemd/` |
