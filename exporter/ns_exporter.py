#!/usr/bin/env python3
"""Nightscout SLI exporter (sre-lab Phase 3, ADR 0008).

Reads the Nightscout API (and, in Kubernetes, the tconnectsync pod's log) and serves the
SLI signals as Prometheus metrics. Standard library only.

Signals
  nightscout_newest_entry_timestamp_seconds        CGM freshness (age = time() - value)
  nightscout_newest_pump_event_timestamp_seconds   staleness guard for tconnectsync
  nightscout_pump_event_latency_seconds            histogram: srvCreated - created_at per pump event
  tconnectsync_polls_total{result}                 poll outcomes parsed from tconnectsync's log
  tconnectsync_container_restarts                  restarts of the tconnectsync container (crash = failed poll)

Configuration (environment)
  NS_URL          Nightscout base URL                      (default http://nightscout:1337)
  API_SECRET      Nightscout API secret; hashed in-process, never logged or exported (required)
  INTERVAL        seconds between collections                 (default 60)
  LISTEN_PORT     metrics port                                (default 9101)
  LOG_SOURCE      "k8s" to read tconnectsync's log through the Kubernetes API, "none" to skip
  POD_SELECTOR    label selector for the tconnectsync pod     (default app=tconnectsync)
  CONTAINER       container name in that pod                  (default tconnectsync)
"""
import hashlib
import json
import os
import re
import signal
import ssl
import sys
import threading
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PUMP_SOURCE = "Pump (tconnectsync)"
LATENCY_BUCKETS = (300, 600, 900, 1800, 2700, 3600, 4500, 5400, 7200, 10800)
SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"

# tconnectsync v3 autoupdate loop: every iteration ends in exactly one of these lines.
POLL_OK = re.compile(r"Sleeping for [\d.]+ sec|Sleeping \d+ seconds after unexpected no index change")
POLL_FAIL = re.compile(r"Error during autoupdate poll \(\d+ consecutive\)")


def parse_time(s):
    """Nightscout timestamps ('2026-11-08T18:50:14.000Z', '2026-11-08 12:55:10-05:00') -> epoch s."""
    return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def ts_key(ts):
    """RFC 3339 timestamp from the Kubernetes log API -> sortable (seconds, nanoseconds).

    The API trims trailing zeros from the fraction, so the strings do not sort correctly."""
    base, _, frac = ts.rstrip("Z").partition(".")
    return (datetime.fromisoformat(base).replace(tzinfo=timezone.utc).timestamp(), int((frac or "0").ljust(9, "0")[:9]))


def utcnow_rfc3339():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000000000Z")


def classify(line):
    if POLL_FAIL.search(line):
        return "failure"
    if POLL_OK.search(line):
        return "success"
    return None


class Histogram:
    def __init__(self, buckets):
        self.buckets = buckets
        self.counts = [0] * len(buckets)
        self.sum = 0.0
        self.count = 0

    def observe(self, v):
        for i, b in enumerate(self.buckets):
            if v <= b:
                self.counts[i] += 1
        self.sum += v
        self.count += 1


class Exporter:
    def __init__(self, ns_url, api_secret, fetch=None, k8s=None, now=time.time):
        self.ns_url = ns_url.rstrip("/")
        self.header = {"api-secret": hashlib.sha1(api_secret.encode()).hexdigest()}
        self.fetch = fetch or http_get_json
        self.k8s = k8s
        self.now = now
        self.lock = threading.Lock()
        self.up = 0
        self.newest_entry = None
        self.newest_pump = None
        self.latency = Histogram(LATENCY_BUCKETS)
        # Count only pump events stored after start-up; history would skew the histogram.
        self.srv_hwm = now() * 1000
        self.polls = {"success": 0, "failure": 0}
        self.log_hwm = None  # RFC 3339 timestamp of the last log line counted
        self.restarts = None
        self.errors = {"api": 0, "k8s": 0}
        self.last_run = 0.0

    # --- Nightscout API -------------------------------------------------------------------
    def collect_api(self):
        q = urllib.parse.quote
        entries = self.fetch(f"{self.ns_url}/api/v1/entries.json?count=1", self.header)
        pumps = self.fetch(
            f"{self.ns_url}/api/v1/treatments.json?count=200&find[enteredBy]={q(PUMP_SOURCE)}",
            self.header)
        newest_entry = max((e["date"] / 1000 for e in entries if isinstance(e.get("date"), (int, float))),
                           default=None)
        newest_pump, fresh, hwm = None, [], self.srv_hwm
        for t in pumps:
            if not t.get("created_at"):
                continue
            ev = parse_time(t["created_at"])
            newest_pump = ev if newest_pump is None else max(newest_pump, ev)
            srv = t.get("srvCreated")
            if isinstance(srv, (int, float)) and srv > self.srv_hwm:
                fresh.append(max(0.0, srv / 1000 - ev))
                hwm = max(hwm, srv)
        with self.lock:
            if newest_entry is not None:
                self.newest_entry = newest_entry
            if newest_pump is not None:
                self.newest_pump = newest_pump
            for v in fresh:
                self.latency.observe(v)
            self.srv_hwm = hwm
            self.up = 1

    # --- tconnectsync log via the Kubernetes API -------------------------------------------
    def collect_log(self):
        pods = self.k8s.pods()
        running = [p for p in pods if p.get("status", {}).get("phase") == "Running"]
        restarts = sum(cs.get("restartCount", 0)
                       for p in pods for cs in p.get("status", {}).get("containerStatuses", []))
        counts = {"success": 0, "failure": 0}
        hwm = self.log_hwm
        for p in running:
            text = self.k8s.log(p["metadata"]["name"], since_time=self.log_hwm)
            for raw in text.splitlines():
                ts, _, line = raw.partition(" ")
                try:
                    key = ts_key(ts)
                except ValueError:
                    continue  # not a timestamped line
                newer = hwm is None or key > ts_key(hwm)
                if self.log_hwm is not None and key > ts_key(self.log_hwm):
                    result = classify(line)  # sinceTime is inclusive, second precision: skip seen
                    if result:
                        counts[result] += 1
                # First pass after start-up only sets the watermark; nothing old is counted.
                if newer:
                    hwm = ts
        with self.lock:
            for k, v in counts.items():
                self.polls[k] += v
            self.log_hwm = hwm if hwm is not None else utcnow_rfc3339()
            self.restarts = restarts

    def collect(self):
        try:
            self.collect_api()
        except Exception as e:  # noqa: BLE001 - any failure is an SLI scrape failure
            with self.lock:
                self.up = 0
                self.errors["api"] += 1
            log(f"api collection failed: {type(e).__name__}: {e}")
        if self.k8s:
            try:
                self.collect_log()
            except Exception as e:  # noqa: BLE001
                with self.lock:
                    self.errors["k8s"] += 1
                log(f"k8s collection failed: {type(e).__name__}: {e}")
        with self.lock:
            self.last_run = self.now()

    # --- exposition -----------------------------------------------------------------------
    def render(self):
        out = []

        def metric(name, kind, help_, samples):
            out.append(f"# HELP {name} {help_}")
            out.append(f"# TYPE {name} {kind}")
            for labels, value in samples:
                out.append(f"{name}{labels} {value}")

        with self.lock:
            metric("nightscout_up", "gauge", "1 if the last Nightscout API collection succeeded.", [("", self.up)])
            if self.newest_entry is not None:
                metric("nightscout_newest_entry_timestamp_seconds", "gauge",
                       "Time of the newest CGM entry.", [("", f"{self.newest_entry:.3f}")])
            if self.newest_pump is not None:
                metric("nightscout_newest_pump_event_timestamp_seconds", "gauge",
                       "Time of the newest tconnectsync pump event.", [("", f"{self.newest_pump:.3f}")])
            h = self.latency
            samples = [(f'{{le="{b}"}}', c) for b, c in zip(h.buckets, h.counts)]
            samples.append(('{le="+Inf"}', h.count))
            metric("nightscout_pump_event_latency_seconds", "histogram",
                   "Delay between a pump event and its storage in Nightscout.", [])
            out.extend(f"nightscout_pump_event_latency_seconds_bucket{lb} {v}" for lb, v in samples)
            out.append(f"nightscout_pump_event_latency_seconds_sum {h.sum:.3f}")
            out.append(f"nightscout_pump_event_latency_seconds_count {h.count}")
            if self.k8s:
                metric("tconnectsync_polls_total", "counter", "Tandem Source polls by outcome, from the log.",
                       [(f'{{result="{k}"}}', v) for k, v in sorted(self.polls.items())])
                if self.restarts is not None:
                    metric("tconnectsync_container_restarts", "gauge",
                           "Restarts of the tconnectsync container.", [("", self.restarts)])
            metric("ns_exporter_errors_total", "counter", "Failed collections by source.",
                   [(f'{{source="{k}"}}', v) for k, v in sorted(self.errors.items())])
            metric("ns_exporter_last_run_timestamp_seconds", "gauge", "End of the last collection.",
                   [("", f"{self.last_run:.3f}")])
        return "\n".join(out) + "\n"


# --- I/O -----------------------------------------------------------------------------------
def log(msg):
    print(f"{datetime.now(timezone.utc).isoformat(timespec='seconds')} {msg}", file=sys.stderr, flush=True)


def http_get(url, headers, timeout=15, context=None):
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout, context=context) as r:
        return r.read().decode()


def http_get_json(url, headers):
    return json.loads(http_get(url, headers))


class K8s:
    """Minimal in-cluster client: list pods by selector, read one container's log."""

    def __init__(self, selector, container):
        with open(f"{SA_DIR}/namespace") as f:
            self.ns = f.read().strip()
        self.base = "https://kubernetes.default.svc"
        self.selector, self.container = selector, container
        self.ctx = ssl.create_default_context(cafile=f"{SA_DIR}/ca.crt")

    def _headers(self):
        with open(f"{SA_DIR}/token") as f:  # re-read: projected tokens rotate
            return {"Authorization": f"Bearer {f.read().strip()}"}

    def pods(self):
        q = urllib.parse.urlencode({"labelSelector": self.selector})
        body = http_get(f"{self.base}/api/v1/namespaces/{self.ns}/pods?{q}", self._headers(), context=self.ctx)
        return json.loads(body)["items"]

    def log(self, pod, since_time=None):
        params = {"container": self.container, "timestamps": "true"}
        if since_time:
            params["sinceTime"] = since_time[:19] + "Z"  # API accepts second precision
        else:
            params["sinceSeconds"] = "600"
        q = urllib.parse.urlencode(params)
        return http_get(f"{self.base}/api/v1/namespaces/{self.ns}/pods/{pod}/log?{q}", self._headers(),
                        context=self.ctx)


def make_server(exporter, port):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path.rstrip("/").endswith("/metrics"):
                body = exporter.render().encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
            elif self.path in ("/healthz", "/"):
                body = b"ok\n"
                self.send_response(200)
                self.send_header("Content-Type", "text/plain")
            else:
                body = b"not found\n"
                self.send_response(404)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    return ThreadingHTTPServer(("", port), Handler)


def main():
    secret = os.environ.get("API_SECRET")
    if not secret:
        sys.exit("API_SECRET is required")
    interval = float(os.environ.get("INTERVAL", "60"))
    k8s = None
    if os.environ.get("LOG_SOURCE", "none") == "k8s":
        k8s = K8s(os.environ.get("POD_SELECTOR", "app=tconnectsync"), os.environ.get("CONTAINER", "tconnectsync"))
    exp = Exporter(os.environ.get("NS_URL", "http://nightscout:1337"), secret, k8s=k8s)

    def loop():
        while True:
            exp.collect()
            time.sleep(interval)

    # As PID 1 in a container, Python ignores SIGTERM unless told otherwise; without this every
    # rollout and rollback waits out the full termination grace period.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    threading.Thread(target=loop, daemon=True).start()
    port = int(os.environ.get("LISTEN_PORT", "9101"))
    log(f"serving on :{port}, interval {interval:.0f}s, log source {'k8s' if k8s else 'none'}")
    make_server(exp, port).serve_forever()


if __name__ == "__main__":
    main()
