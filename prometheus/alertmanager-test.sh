#!/usr/bin/env bash
# Routing tests for prometheus/alertmanager.yml: `amtool check-config`, then one assertion per
# alert class (label set -> expected receiver). Usage: AMTOOL="<command>" prometheus/alertmanager-test.sh CONFIG
set -euo pipefail
cfg=${1:?usage: alertmanager-test.sh CONFIG}
amtool=${AMTOOL:-amtool}
$amtool check-config "$cfg"
fails=0
expect(){ local want=$1; shift
  got=$($amtool config routes test --config.file="$cfg" "$@" 2>&1 | tr -d '\r' | tail -1)
  if [ "$got" = "$want" ]; then echo "ok   $* -> $got"; else echo "FAIL $* -> '$got', want '$want'"; fails=1; fi; }
expect pagerduty-page   alertname=NightscoutAPIAvailabilityBudgetBurn severity=page sloth_slo=api-availability instance=k3s-copy
expect pagerduty-page   alertname=NightscoutCGMFreshnessBudgetBurn severity=page sloth_slo=cgm-freshness instance=k3s-copy
expect pagerduty-page   alertname=TconnectsyncPollFailureBudgetBurn severity=page sloth_slo=tconnectsync-polls instance=k3s-copy
expect pagerduty-ticket alertname=PumpDataLatencyBudgetBurn severity=ticket sloth_slo=pump-latency instance=k3s-copy
expect pagerduty-ticket alertname=NightscoutExporterDown severity=ticket instance=live
expect pagerduty-ticket alertname=PrometheusRuleEvaluationFailures severity=ticket
expect heartbeat        alertname=Watchdog severity=none
expect blackhole        alertname=UpstreamCGMStale severity=info instance=k3s-copy
expect pagerduty-ticket alertname=SomethingNew                          # unlabelled: still reaches a human
exit "$fails"
