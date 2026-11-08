"""Tests for ns_exporter. Standard library only: python3 -m unittest -v exporter/test_ns_exporter.py"""
import hashlib
import json
import os
import sys
import threading
import unittest
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ns_exporter as nx  # noqa: E402

T0 = 1_794_000_000.0  # fixed "now" (2026-11-08)
SECRET = "correct horse battery staple"


def iso(epoch):
    from datetime import datetime, timezone
    return datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def pump(event_epoch, stored_epoch):
    return {"created_at": iso(event_epoch), "srvCreated": int(stored_epoch * 1000),
            "enteredBy": nx.PUMP_SOURCE, "eventType": "Temp Basal"}


class FakeNS:
    """Returns canned API responses and records the requests."""

    def __init__(self, entries=None, treatments=None):
        self.entries, self.treatments, self.calls, self.fail = entries or [], treatments or [], [], False

    def __call__(self, url, headers):
        self.calls.append((url, headers))
        if self.fail:
            raise OSError("connection refused")
        return self.entries if "/entries.json" in url else self.treatments


class FakeK8s:
    def __init__(self):
        self.pods_ = []
        self.logs = {}
        self.since = []

    def pods(self):
        return self.pods_

    def log(self, pod, since_time=None):
        self.since.append(since_time)
        return self.logs.get(pod, "")


def pod(name, phase="Running", restarts=0):
    return {"metadata": {"name": name},
            "status": {"phase": phase, "containerStatuses": [{"restartCount": restarts}]}}


OK1 = "2026-11-08 20:14:26 INFO     Sleeping for 300.0 sec"
OK2 = "2026-11-08 20:20:00 WARNING  Sleeping 60 seconds after unexpected no index change based on previous cadence."
FAIL = ("2026-11-08 20:25:00 WARNING  Error during autoupdate poll (1 consecutive): TandemSourceApi HTTP 502. "
        "Sleeping 30s before retry.")
RETRY = "2026-11-08 18:28:26 WARNING  Received ApiException in TandemSourceApi with endpoint 'x' (tries 0): HTTP 401"


class Parsing(unittest.TestCase):
    def test_parse_time_formats(self):
        a = nx.parse_time("2026-11-08T18:50:14.000Z")
        b = nx.parse_time("2026-11-08 13:50:14-05:00")
        self.assertEqual(a, b)

    def test_ts_key_orders_trimmed_fractions(self):
        # String order says .1234Z > .123456789Z is false/true inconsistently; keys must not.
        self.assertGreater(nx.ts_key("2026-11-08T20:14:26.1235Z"), nx.ts_key("2026-11-08T20:14:26.123456789Z"))
        self.assertLess(nx.ts_key("2026-11-08T20:14:26.5Z"), nx.ts_key("2026-11-08T20:14:27Z"))
        self.assertEqual(nx.ts_key("2026-11-08T20:14:26Z"), nx.ts_key("2026-11-08T20:14:26.000000000Z"))

    def test_classify(self):
        self.assertEqual(nx.classify(OK1), "success")
        self.assertEqual(nx.classify(OK2), "success")
        self.assertEqual(nx.classify(FAIL), "failure")
        self.assertIsNone(nx.classify(RETRY), "in-request retries are not poll outcomes")
        self.assertIsNone(nx.classify("2026-11-08 20:14:25 INFO     Found 2 pumps"))


class Api(unittest.TestCase):
    def setUp(self):
        self.ns = FakeNS(entries=[{"date": int((T0 - 120) * 1000), "sgv": 120}])
        self.exp = nx.Exporter("http://ns:1337/", SECRET, fetch=self.ns, now=lambda: T0)

    def test_sends_hashed_secret_and_queries_tconnectsync_only(self):
        self.exp.collect()
        (u1, h1), (u2, _) = self.ns.calls
        self.assertEqual(h1, {"api-secret": hashlib.sha1(SECRET.encode()).hexdigest()})
        self.assertEqual(u1, "http://ns:1337/api/v1/entries.json?count=1")
        self.assertIn("find[enteredBy]=Pump%20%28tconnectsync%29", u2)

    def test_freshness_and_newest_pump(self):
        self.ns.treatments = [pump(T0 - 900, T0 - 600), pump(T0 - 600, T0 - 600)]
        self.exp.collect()
        self.assertEqual(self.exp.up, 1)
        self.assertAlmostEqual(self.exp.newest_entry, T0 - 120)
        self.assertAlmostEqual(self.exp.newest_pump, T0 - 600)

    def test_latency_counts_each_event_once_and_ignores_history(self):
        self.ns.treatments = [pump(T0 - 4000, T0 - 3000)]  # stored before start-up: ignored
        self.exp.collect()
        self.assertEqual(self.exp.latency.count, 0)
        self.ns.treatments = [pump(T0 - 2400, T0 + 60), pump(T0 - 300, T0 + 60), pump(T0 - 4000, T0 - 3000)]
        self.exp.collect()
        self.exp.collect()  # same data again: nothing new
        h = self.exp.latency
        self.assertEqual(h.count, 2)
        self.assertAlmostEqual(h.sum, 2460 + 360)
        self.assertEqual(dict(zip(h.buckets, h.counts))[600], 1)
        self.assertEqual(dict(zip(h.buckets, h.counts))[2700], 2)

    def test_negative_latency_clamped(self):
        self.ns.treatments = [pump(T0 + 120, T0 + 60)]  # pump clock ahead of server
        self.exp.collect()
        self.assertEqual(self.exp.latency.sum, 0.0)

    def test_api_failure_keeps_last_values_and_counts_error(self):
        self.exp.collect()
        self.ns.fail = True
        self.exp.collect()
        self.assertEqual(self.exp.up, 0)
        self.assertEqual(self.exp.errors["api"], 1)
        self.assertAlmostEqual(self.exp.newest_entry, T0 - 120)

    def test_render_has_no_secret_and_valid_histogram(self):
        self.ns.treatments = [pump(T0 - 300, T0 + 60)]
        self.exp.collect()
        text = self.exp.render()
        self.assertNotIn(SECRET, text)
        self.assertNotIn(hashlib.sha1(SECRET.encode()).hexdigest(), text)
        self.assertIn('nightscout_pump_event_latency_seconds_bucket{le="+Inf"} 1', text)
        self.assertIn("nightscout_newest_entry_timestamp_seconds 1793999880.000", text)
        self.assertNotIn("tconnectsync_polls_total", text, "no log source configured")
        buckets = [int(l.rsplit(" ", 1)[1]) for l in text.splitlines()
                   if l.startswith("nightscout_pump_event_latency_seconds_bucket")]
        self.assertEqual(buckets, sorted(buckets), "buckets must be cumulative")


class Log(unittest.TestCase):
    def setUp(self):
        self.k8s = FakeK8s()
        self.exp = nx.Exporter("http://ns", SECRET, fetch=FakeNS(), k8s=self.k8s, now=lambda: T0)

    def test_first_pass_counts_nothing_then_counts_new_lines_once(self):
        self.k8s.pods_ = [pod("tc-1")]
        self.k8s.logs["tc-1"] = f"2026-11-08T20:14:26.5Z {OK1}\n"
        self.exp.collect_log()
        self.assertEqual(self.exp.polls, {"success": 0, "failure": 0})
        self.assertEqual(self.exp.log_hwm, "2026-11-08T20:14:26.5Z")
        # sinceTime is second-precision and inclusive: the old line comes back with the new ones.
        self.k8s.logs["tc-1"] = (f"2026-11-08T20:14:26.5Z {OK1}\n"
                                 f"2026-11-08T20:14:26.500001Z {OK2}\n"  # newer, though it sorts lower as text
                                 f"2026-11-08T20:14:26.75Z {RETRY}\n"
                                 f"2026-11-08T20:20:00.1Z {OK2}\n"
                                 f"2026-11-08T20:25:00.123456789Z {FAIL}\n")
        self.exp.collect_log()
        self.assertEqual(self.exp.polls, {"success": 2, "failure": 1})
        self.assertEqual(self.k8s.since[-1], "2026-11-08T20:14:26.5Z")
        self.exp.collect_log()
        self.assertEqual(self.exp.polls, {"success": 2, "failure": 1}, "no double counting")

    def test_empty_log_sets_watermark_to_now(self):
        self.k8s.pods_ = [pod("tc-1")]
        self.exp.collect_log()
        self.assertIsNotNone(self.exp.log_hwm)
        self.assertTrue(self.exp.log_hwm.endswith("Z"))

    def test_restarts_summed_and_only_running_pods_read(self):
        self.k8s.pods_ = [pod("tc-old", phase="Failed", restarts=2), pod("tc-new", restarts=1)]
        self.exp.collect_log()
        self.assertEqual(self.exp.restarts, 3)
        self.assertEqual(len(self.k8s.since), 1, "logs read only from the running pod")

    def test_k8s_error_counted_and_api_still_collected(self):
        class Broken(FakeK8s):
            def pods(self):
                raise OSError("forbidden")
        exp = nx.Exporter("http://ns", SECRET, fetch=FakeNS(entries=[{"date": T0 * 1000}]), k8s=Broken(),
                          now=lambda: T0)
        exp.collect()
        self.assertEqual(exp.errors, {"api": 0, "k8s": 1})
        self.assertEqual(exp.up, 1)
        self.assertIn('tconnectsync_polls_total{result="failure"} 0', exp.render())


class EndToEnd(unittest.TestCase):
    """Real HTTP both ways: fake Nightscout <- exporter -> /metrics."""

    def test_metrics_over_http(self):
        want = hashlib.sha1(SECRET.encode()).hexdigest()
        seen = {}

        class NS(BaseHTTPRequestHandler):
            def do_GET(self):
                seen["secret"] = self.headers.get("api-secret")
                if self.headers.get("api-secret") != want:
                    self.send_response(401); self.end_headers(); return
                body = json.dumps([{"date": int(T0 * 1000)}] if "entries" in self.path else []).encode()
                self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers()
                self.wfile.write(body)

            def log_message(self, *a):
                pass

        ns = ThreadingHTTPServer(("127.0.0.1", 0), NS)
        threading.Thread(target=ns.serve_forever, daemon=True).start()
        exp = nx.Exporter(f"http://127.0.0.1:{ns.server_port}", SECRET)
        exp.collect()
        srv = nx.make_server(exp, 0)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        try:
            base = f"http://127.0.0.1:{srv.server_port}"
            body = urllib.request.urlopen(f"{base}/nsexporter/metrics").read().decode()
            self.assertIn("nightscout_up 1", body)
            self.assertIn(f"nightscout_newest_entry_timestamp_seconds {T0:.3f}", body)
            self.assertEqual(urllib.request.urlopen(f"{base}/healthz").read(), b"ok\n")
            with self.assertRaises(urllib.error.HTTPError):
                urllib.request.urlopen(f"{base}/other")
        finally:
            srv.shutdown(); ns.shutdown()
        self.assertEqual(seen["secret"], want)


if __name__ == "__main__":
    unittest.main()
