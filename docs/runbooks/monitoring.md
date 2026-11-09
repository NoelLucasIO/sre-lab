# Monitoring itself

**Alerts:** `NightscoutExporterDown`, `BlackboxProbesMissing`, `PrometheusRuleEvaluationFailures` (ticket), `Watchdog` (always firing)
**Why they matter:** when a signal disappears, the SLOs do not turn red, they go silent. These alerts make "blind" visible.

## NightscoutExporterDown

```bash
pq 'up{job="nightscout-exporter"}'        # which instance: k3s-copy or live
```

- **k3s-copy:** `KC get pods -l app=ns-exporter`; `KC logs deploy/ns-exporter --tail=30`. Through the ingress: `curl -s http://192.168.2.40/nsexporter/metrics | head`. The target is node .40 only: if that node is down, this alert fires too (see [api-availability](api-availability.md) for node checks).
- **live:** `systemctl --user status ns-exporter-live --no-pager`; `podman logs --tail 30 ns-exporter-live`; `curl -s 127.0.0.1:9102/metrics | head`. Restart: `systemctl --user restart ns-exporter-live`.
- `ns_exporter_errors_total{source="api"}` rising: the exporter runs but cannot read Nightscout (wrong secret gives 401 in its log).

## BlackboxProbesMissing

```bash
systemctl --user status blackbox --no-pager | grep Active
podman logs --tail 30 blackbox
curl -s '127.0.0.1:9115/probe?module=ns_live&target=http://127.0.0.1:1337/api/v1/status.json' | grep probe_success
```

Config: `/990/blackbox/blackbox.yml` (repo: `prometheus/blackbox.yml`). Header secrets: Podman secrets `ns-k3s-api-hash`, `ns-live-api-hash`.

## PrometheusRuleEvaluationFailures

Prometheus auto-updates (`:latest`, ADR 0008); a new release can break a rule.

```bash
curl -s localhost:9091/api/v1/rules | python3 -c 'import json,sys
for g in json.load(sys.stdin)["data"]["groups"]:
    for r in g["rules"]:
        if r.get("health")!="ok": print(g["name"], r.get("name"), r.get("lastError"))'
podman exec prometheus prometheus --version | head -1      # the version fedora runs now
```

Fix the rule in the repo (`prometheus/slo/` or `prometheus/rules/inputs.yml`), bump `PROMETHEUS_IMAGE` in `.github/workflows/rules.yml` to the version fedora now runs so CI tests it, merge, copy the files to `/990/prometheus/config/sre-lab/rules/`, then `podman exec prometheus promtool check config /etc/prometheus/prometheus.yml && ~/reload-prometheus.sh`.

## Watchdog

Always firing, by design. Alertmanager forwards it as a heartbeat; when it stops arriving, Prometheus or Alertmanager is down. No action while it fires.

## Rule and fragment files on fedora

Configs are mounted as **directories**, so a reload sees a replaced file. (A single-file bind mount keeps the old inode: the reload returns 200 and changes nothing.) The directory must be readable by the container's user (`chmod 755`): Blackbox and Alertmanager run as `nobody`, and a `700` directory fails with `permission denied` on start.


| Repo | fedora |
|---|---|
| `prometheus/rules/inputs.yml`, `prometheus/rules/sloth/*.yml` | `/990/prometheus/config/sre-lab/rules/…` (via `rule_files` in `prometheus.yml`) |
| `prometheus/scrape/*.yml` | `/990/prometheus/config/sre-lab/scrape/` (via `scrape_config_files`) |
| `prometheus/blackbox.yml` | `/990/blackbox/blackbox.yml` (directory mounted) |
| `prometheus/alertmanager.yml` | `/990/alertmanager/config/alertmanager.yml` (directory mounted); apply with `curl -X POST 127.0.0.1:9095/-/reload` |
| `prometheus/*.container` | `~/.config/containers/systemd/` |
