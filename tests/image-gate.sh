#!/bin/bash
# Boot gate for the tig image, run INSIDE the image sdlc builds from this PR.
#
# Usage (from [tool.sdlc.ci.boot-gate]): bash tests/image-gate.sh
#
# This is tests/test-image.sh with the container runtime taken out. sdlc's
# `command` check starts ONE container from the built image, with the repo
# mounted read-only at /repo, no network but loopback, and every capability
# dropped. So instead of three containers on a bridge network, the three roles
# run here as background processes on loopback: influxd, the shipped
# telegraf-receiver config, and Grafana with the shipped provisioning. The
# container is tests/Containerfile.gate, the Containerfile as uid 1502: root with
# no capabilities cannot read Grafana's 0700 home. There is no /etc/hosts to
# edit as that user, so the one shipped file that names a peer (the datasource
# URL) is rewritten in a copy, and everything else addresses 127.0.0.1.
#
# Same assertions as test-image.sh, with these exceptions, which cannot run in
# one container: the "MCP server" section (it runs the upstream
# grafana/mcp-grafana image, a second container), and influxd running as uid
# 1501 (everything here is 1502, with state under /tmp).

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
export HOME=/tmp
TMP="$(mktemp -d /tmp/tig-gate.XXXXXX)"

check() {
    local desc="$1"
    shift
    local output
    if output=$("$@" 2>&1); then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        [ -n "$output" ] && echo "        $output"
        FAIL=$((FAIL + 1))
    fi
}

# `producer | grep -q` is a trap under pipefail: grep exits at the first match,
# the producer dies of SIGPIPE mid-write, and the pipeline reports failure.
# This reads everything first, then matches.
contains() {
    local haystack
    haystack="$(cat)"
    grep -q -- "$1" <<<"$haystack"
}

wait_for() {
    local desc="$1" tries=45
    shift
    until "$@" >/dev/null 2>&1; do
        tries=$((tries - 1))
        [ "$tries" -le 0 ] && { echo "  timeout waiting for $desc"; return 1; }
        sleep 2
    done
}

echo "=== Static tests ==="
# The gate image is built from tests/Containerfile.gate, a copy of the
# Containerfile plus one USER line, so it never waits on another build. This
# keeps the copy honest: any drift and the gate is not testing this PR's image.
gate_matches_containerfile() {
    [ "$(cat "$REPO/tests/Containerfile.gate")" = "$(cat "$REPO/Containerfile"; printf '\nUSER 1502:1502')" ]
}
check "tests/Containerfile.gate is the Containerfile plus USER 1502:1502" gate_matches_containerfile

check "telegraf runs"            telegraf --version
check "influxd runs"             influxd version
check "influx CLI runs"          influx version
check "grafana runs"             grafana --version
check "python3 present"          python3 --version
check "dispatcher executable"    test -x /usr/local/bin/tig
check "bootstrap executable"     test -x /usr/local/bin/influxdb-bootstrap
check "fd walker executable"     test -x /usr/local/libexec/telegraf/fd_types.py
check "db collector executable"  test -x /usr/local/libexec/telegraf/ctr_db_status.py
check "rollup task shipped"      test -r /usr/local/share/tig/rollup.flux
check "firing helper executable" test -x /usr/local/bin/grafana-firing
check "firing helper fails without grafana" \
    bash -c 'GF_SECURITY_ADMIN_USER=a GF_SECURITY_ADMIN_PASSWORD=b /usr/local/bin/grafana-firing; test $? -eq 1'
check "influxdb uid is 1501"     test "$(id -u influxdb)" = 1501
check "grafana uid is 1502"      test "$(id -u grafana)" = 1502
check "unknown role exits 64"    bash -c '/usr/local/bin/tig bogus; test $? -eq 64'
fd_walker_emits_line_protocol() {
    /usr/local/libexec/telegraf/fd_types.py | grep -Eq '^fd_types_total files=[0-9]+i,'
}
check "fd walker emits line protocol" fd_walker_emits_line_protocol

# RT#1567, RT#1598: the exec commands in the shipped config are nested
# ["prog", "arg"] arrays. The flat string form telegraf used to want is
# deprecated since 1.39.0 and removed in 1.45.0, and the array is what carries
# ctr_db_status.py its config path. If that argument were ever lost the script
# would silently read its default config, the database counters would go to a
# container nobody asked about, and nothing in the data would look wrong -- the
# same silent shape as the bug RT#1567 chased.
#
# So assert the argument actually arrives, rather than that the config parses:
# point the script at a config naming one container that does not exist, and
# require that name back in the output. If the argument were lost the script
# would read its default config instead and never mention it.
exec_command_argument_reaches_argv() {
    local dir out
    dir="$TMP/probe"
    mkdir -p "$dir"
    printf 'probe-not-a-container mariadb\n' > "$dir/db-probe.conf"
    cat > "$dir/probe.conf" <<PROBE
[agent]
  interval = "10s"
  omit_hostname = true
[[inputs.exec]]
  commands = [["/usr/local/libexec/telegraf/ctr_db_status.py", "$dir/db-probe.conf"]]
  timeout = "20s"
  data_format = "influx"
PROBE
    out="$(telegraf --config "$dir/probe.conf" --test 2>&1)"
    contains "db_collector,container=probe-not-a-container up=0i" <<<"$out" && return 0
    # Report what telegraf actually said, so a failure explains itself.
    echo "telegraf output was:"
    printf '%s\n' "$out"
    return 1
}
check "exec command argument reaches argv" exec_command_argument_reaches_argv

echo "=== Runtime tests ==="

# Every daemon's state lives under /tmp; the rest of the filesystem is not ours.
export INFLUXD_BOLT_PATH="$TMP/influxdb/influxd.bolt" INFLUXD_ENGINE_PATH="$TMP/influxdb/engine"
export INFLUXDB_INIT_USERNAME=admin INFLUXDB_INIT_PASSWORD=test-password-123
export INFLUXDB_INIT_ORG=crunchtools INFLUXDB_INIT_BUCKET=telegraf
export INFLUXDB_INIT_ADMIN_TOKEN=test-admin-token
INFLUXD_CONFIG_PATH="$REPO/deploy/influxdb/config.yml" \
    /usr/local/bin/tig influxd >"$TMP/influxd.log" 2>&1 &

check "influxd becomes healthy" \
    wait_for influxd curl -sf http://127.0.0.1:8086/health
check "bootstrap succeeds" \
    /usr/local/bin/influxdb-bootstrap
check "bootstrap is idempotent" \
    /usr/local/bin/influxdb-bootstrap
check "rollup bucket exists" \
    bash -c "influx bucket list --org crunchtools --token test-admin-token | grep -q telegraf_rollup"
check "rollup task exists" \
    bash -c "influx task list --org crunchtools --token test-admin-token | grep -q rollup-1h"

WRITE_TOKEN="$(/usr/local/bin/influxdb-bootstrap token write)"
READ_TOKEN="$(/usr/local/bin/influxdb-bootstrap token read)"
check "write token minted" test -n "$WRITE_TOKEN"
check "read token minted"  test -n "$READ_TOKEN"

# Load the WHOLE shipped config, every plugin. An option a plugin no longer
# accepts is fatal at startup, and a deprecated one will be: the filtered run
# below never loads the docker, net or disk inputs, so it cannot catch either.
# Gather errors (no Podman socket here) are expected and ignored; only what
# Telegraf says about the config itself matters.
full_config_loads_cleanly() {
    local output
    output="$(INFLUX_URL=http://127.0.0.1:8086 INFLUX_ORG=crunchtools \
        INFLUX_BUCKET=telegraf INFLUX_TOKEN=unused \
        telegraf --config "$REPO/deploy/telegraf-host/telegraf.conf" --test 2>&1 || true)"
    if grep -E 'loading config file .* failed|DeprecationWarning' <<<"$output"; then
        return 1
    fi
    grep -q '^> mem,' <<<"$output"
}
check "full telegraf config loads with no errors or deprecations" full_config_loads_cleanly

# The shipped config, restricted to inputs that need no host access.
telegraf_writes() {
    INFLUX_URL=http://127.0.0.1:8086 INFLUX_ORG=crunchtools \
        INFLUX_BUCKET=telegraf INFLUX_TOKEN="$WRITE_TOKEN" \
        telegraf --config "$REPO/deploy/telegraf-host/telegraf.conf" \
        --input-filter cpu:mem:swap:system:exec --once
}
check "telegraf writes with the shipped config" telegraf_writes

check "read token can query the point back" \
    bash -c "influx query --org crunchtools --token '$READ_TOKEN' \
        'from(bucket:\"telegraf\") |> range(start:-5m) |> filter(fn:(r)=>r._measurement==\"mem\") |> limit(n:1)' | grep -q available"
# The tokens are only worth minting if they are actually scoped.
write_token_cannot_read() {
    ! influx query --org crunchtools --token "$WRITE_TOKEN" \
        'from(bucket:"telegraf") |> range(start:-5m) |> limit(n:1)' 2>/dev/null | contains _value
}
read_token_cannot_write() {
    ! influx write --org crunchtools --bucket telegraf \
        --token "$READ_TOKEN" 'forged value=1' >/dev/null 2>&1
}
# RT#1567: influxdb-freshness now requires the CONTAINER pipeline as well as
# system/load1. inputs.docker cannot gather in here (no Podman socket), so seed
# one docker_container_mem point to stand for a healthy container pipeline.
influx write --org crunchtools --bucket telegraf \
    --token test-admin-token 'docker_container_mem,container_name=seed usage=1i' >/dev/null

freshness_reports_recent_age() {
    local age
    age="$(/usr/local/bin/influxdb-freshness)"
    echo "influxdb-freshness printed: '$age'"
    [ "$age" -ge 0 ] && [ "$age" -lt 300 ]
}
# The actual lesson of RT#1567, and the one check here that would have caught
# it: a fresh host pipeline must NOT be enough to satisfy this. system/load1 is
# present and recent at this point, so asking additionally for a container
# series that was never written must still report the no-data case, which the
# NRPE plugin maps to CRITICAL. Without this, every container metric can be dead
# for days behind a green check.
freshness_requires_the_container_pipeline() {
    [ "$(/usr/local/bin/influxdb-freshness system:load1 docker_container_mem:nosuchfield)" = "-1" ]
}
check "write token cannot read"                write_token_cannot_read
check "read token cannot write"                read_token_cannot_write
check "freshness helper reports a recent age"  freshness_reports_recent_age
check "freshness requires the container pipeline, not just the host" \
    freshness_requires_the_container_pipeline
# Nothing has been rolled up yet, so the rollup bucket is the no-data case.
freshness_reports_no_data() {
    [ "$(INFLUXDB_INIT_BUCKET=telegraf_rollup /usr/local/bin/influxdb-freshness)" = "-1" ]
}
check "freshness helper reports -1 with no data" freshness_reports_no_data

# The task only fires on the hour, so run its script as a query. That executes
# the real Flux — the import, both aggregations and the write — against the
# points Telegraf just stored.
rollup_script_runs() {
    INFLUX_HOST=http://127.0.0.1:8086 INFLUX_TOKEN=test-admin-token \
        influx query --org crunchtools --file /usr/local/share/tig/rollup.flux >/dev/null
}
rollup_bucket_has() {
    influx query --org crunchtools --token "$READ_TOKEN" \
        "from(bucket:\"telegraf_rollup\") |> range(start:-2h, stop: 2h) |> filter(fn:(r)=>r._measurement==\"$1\") |> limit(n:1)" \
        | contains "$1"
}
check "rollup script executes"               rollup_script_runs
check "rollup wrote a gauge (mem)"           rollup_bucket_has mem
check "rollup wrote the fd totals"           rollup_bucket_has fd_types_total
check "fd walker data reached influxdb" \
    bash -c "influx query --org crunchtools --token '$READ_TOKEN' \
        'from(bucket:\"telegraf\") |> range(start:-5m) |> filter(fn:(r)=>r._measurement==\"fd_types_total\") |> limit(n:1)' | grep -q fd_types_total"

echo "=== OTLP receiver (shipped telegraf-receiver config, a payload from Trentina's exporter) ==="

# tests/fixtures/otlp-trentina.json is what trentina's telemetry.otlp_payload
# produces for five calls; the receiver must turn each span into one point.
INFLUX_URL=http://127.0.0.1:8086 INFLUX_ORG=crunchtools \
    INFLUX_BUCKET=telegraf INFLUX_TOKEN="$WRITE_TOKEN" \
    OTLP_USERNAME=trentina OTLP_PASSWORD=otlp-test-password \
    telegraf --config "$REPO/deploy/telegraf-receiver/telegraf.conf" >"$TMP/receiver.log" 2>&1 &

otlp_post() {
    curl -s -o /dev/null -w '%{http_code}' -m 10 "$@" \
        -H 'Content-Type: application/json' --data-binary @"$REPO/tests/fixtures/otlp-trentina.json" \
        http://127.0.0.1:4318/v1/traces
}
otlp_up() { [ "$(otlp_post -u trentina:otlp-test-password)" = 204 ]; }
otlp_refuses_without_auth() { [ "$(otlp_post)" = 401 ]; }
otlp_refuses_wrong_auth() { [ "$(otlp_post -u trentina:wrong)" = 401 ]; }
otlp_points_count() {
    influx query --org crunchtools --token "$READ_TOKEN" --raw \
        'from(bucket:"telegraf") |> range(start: 2026-11-01T00:00:00Z) |> filter(fn:(r)=>r._measurement=="trentina_calls" and r._field=="duration_ms") |> group() |> count()' \
        | tr -d '\r' | grep -oE ',[0-9]+$' | tr -d ,
}
otlp_points_arrived() { [ "$(otlp_points_count)" = 5 ]; }
otlp_blocked_call_tagged() {
    influx query --org crunchtools --token "$READ_TOKEN" --raw \
        'from(bucket:"telegraf") |> range(start: 2026-11-01T00:00:00Z) |> filter(fn:(r)=>r._measurement=="trentina_calls" and r.outcome=="blocked_defense" and r.layer=="L2" and r.risk=="high")' \
        | contains duration_ms
}

check "receiver accepts a span batch with basic auth"  wait_for otlp-receiver otlp_up
check "receiver refuses a batch without auth"          otlp_refuses_without_auth
check "receiver refuses a batch with the wrong password" otlp_refuses_wrong_auth
check "five spans became five points"                 wait_for "otlp points" otlp_points_arrived
check "a blocked call keeps its layer and risk tags"   otlp_blocked_call_tagged

echo "=== Trentina dashboard (every shipped query runs against test data) ==="

# Grafana fills v.timeRangeStart, v.timeRangeStop and v.windowPeriod; outside
# it, a query defines them itself. Each must run and return at least one row.
dashboard_queries_run() {
    python3 - "$REPO/deploy/grafana/dashboards/trentina.json" <<'PY' > "$TMP/trentina-queries.txt"
import json, sys
dashboard = json.load(open(sys.argv[1]))
# The dashboard is crunchtools/trentina's portable copy: the bucket is a
# dashboard variable, filled here from its own default, as Grafana fills it.
bucket = next(v for v in dashboard["templating"]["list"] if v["name"] == "bucket")["query"]
for panel in dashboard["panels"]:
    for target in panel["targets"]:
        query = target["query"].replace("${bucket}", bucket)
        print(json.dumps({"title": panel["title"], "query": query}))
PY
    local failed=0 title query flux out
    while IFS= read -r entry; do
        title="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["title"])' "$entry")"
        query="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["query"])' "$entry")"
        flux="$(python3 -c '
import sys
q = sys.argv[1]
head = "v = {timeRangeStart: 2026-11-01T00:00:00Z, timeRangeStop: now(), windowPeriod: 1h}\n"
lines = q.split("\n")
imports = [l for l in lines if l.startswith("import ")]
rest = [l for l in lines if not l.startswith("import ")]
print("\n".join(imports + [head] + rest))
' "$query")"
        # --raw is annotated CSV: a header row starting "," and then the rows.
        if ! out="$(influx query --org crunchtools --token "$READ_TOKEN" --raw "$flux" 2>&1)" \
            || [ "$(grep -v '^#' <<<"$out" | grep -c '^,')" -lt 2 ]; then
            echo "panel '$title' failed: $(head -c 300 <<<"$out")"
            failed=1
        fi
    done < "$TMP/trentina-queries.txt"
    return $failed
}
check "every Trentina dashboard query returns rows" dashboard_queries_run
# trentina.json is a copy of crunchtools/trentina contrib/grafana/trentina-dashboard.json,
# which is where it is edited; this catches a hand edit made here instead.
trentina_dashboard_is_the_shared_copy() {
    python3 - "$REPO/deploy/grafana/dashboards/trentina.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert "Source: crunchtools/trentina contrib/grafana" in d["description"], d["description"]
assert {v["name"] for v in d["templating"]["list"]} == {"datasource", "bucket"}
assert all(p.get("description") for p in d["panels"]), "every panel has a tooltip"
variables = {v["name"]: v for v in d["templating"]["list"]}
assert variables["bucket"]["query"] == "telegraf", "our bucket is the default"
assert variables["datasource"]["type"] == "datasource" and variables["datasource"]["query"] == "influxdb"
for p in d["panels"]:
    sources = [p["datasource"]] + [t["datasource"] for t in p["targets"]]
    assert all(s == {"type": "influxdb", "uid": "${datasource}"} for s in sources), p["title"]
    assert all('from(bucket: "${bucket}")' in t["query"] for t in p["targets"]), p["title"]
PY
}
check "Trentina dashboard is the shared trentina copy" trentina_dashboard_is_the_shared_copy

# Grafana reads /etc/grafana, which production mounts from deploy/grafana. Here
# the shipped tree is copied under /tmp, with /etc/grafana and the datasource's
# peer name (influxdb) rewritten to match; the command is the dispatcher's.
GF_ETC="$TMP/grafana-etc"
mkdir -p "$GF_ETC" && cp -r "$REPO/deploy/grafana/." "$GF_ETC/"
sed -i -e "s#/etc/grafana#$GF_ETC#g" "$GF_ETC/grafana.ini" "$GF_ETC/provisioning/dashboards/dashboards.yaml"
sed -i -e 's#http://influxdb:8086#http://127.0.0.1:8086#' "$GF_ETC/provisioning/datasources/influxdb.yaml"
export GF_PATHS_DATA="$TMP/grafana" GF_PATHS_LOGS="$TMP/grafana/log" GF_PATHS_PLUGINS="$TMP/grafana/plugins"
export GF_SECURITY_ADMIN_USER=admin GF_SECURITY_ADMIN_PASSWORD=test-password-123
export INFLUXDB_TOKEN="$READ_TOKEN" ALERT_WEBHOOK_URL=http://127.0.0.1:9000/alert ALERT_WEBHOOK_TOKEN=sink-token
/usr/sbin/grafana server --homepath /usr/share/grafana --config "$GF_ETC/grafana.ini" >"$TMP/grafana.log" 2>&1 &

grafana_api() {
    curl -sf -u admin:test-password-123 "http://127.0.0.1:3000$1"
}

check "grafana becomes healthy with shipped provisioning" \
    wait_for grafana curl -sf http://127.0.0.1:3000/api/health

datasource_provisioned() { grafana_api /api/datasources/uid/influxdb | contains '"type":"influxdb"'; }
datasource_healthy()     { grafana_api /api/datasources/uid/influxdb/health | contains '"status":"OK"'; }
dashboards_provisioned() { [ "$(grafana_api '/api/search?tag=tig' | grep -o '"uid":"tig-' | wc -l)" -eq 5 ]; }
alert_rules_provisioned() { [ "$(grafana_api /api/v1/provisioning/alert-rules | grep -o '"uid":"' | wc -l)" -ge 4 ]; }

check "datasource provisioned"       datasource_provisioned
# Grafana answers /api/health a few seconds before its bundled InfluxDB plugin
# has been unpacked and started, so these two wait rather than race it.
plugin_backends() { ps -e -o args= | grep '[/]gpx_'; }  # [/]: not this grep
influxdb_plugin_running() { plugin_backends | contains gpx_grafana_influxdb; }
one_plugin_backend() { [ "$(plugin_backends | grep -c gpx_)" -eq 1 ]; }

check "influxdb plugin backend starts"        wait_for "influxdb plugin" influxdb_plugin_running
check "datasource reaches influxdb"           wait_for "datasource health" datasource_healthy
check "no other plugin backend is running"    one_plugin_backend
check "five dashboards provisioned"  dashboards_provisioned
check "four alert rules provisioned" alert_rules_provisioned

# Trend alerts must not page: every alert lands on a route muted around the
# clock, and Nagios reads the firing rules through grafana-firing instead.
always_mute_provisioned() { grafana_api /api/v1/provisioning/mute-timings | contains '"name":"always"'; }
catch_all_route_muted() {
    grafana_api /api/v1/provisioning/policies | python3 -c '
import json, sys
tree = json.load(sys.stdin)
routes = tree.get("routes") or []
assert any(not r.get("object_matchers") and not r.get("matchers") and r.get("mute_time_intervals") == ["always"]
           for r in routes), tree
'
}
firing_helper_reads_grafana() { /usr/local/bin/grafana-firing; }
check "always-on mute timing provisioned"   always_mute_provisioned
check "every alert routes to the muted route" catch_all_route_muted
check "firing helper reads the rules"       firing_helper_reads_grafana

echo "=== disk-time-to-full (shipped rule, synthetic day of disk data) ==="

# The rule is read back from Grafana and its queries and expressions are run
# through the alerting evaluator, so this is the condition that ships. An
# image pull is the case it exists for: a step that the 6-hour rate alone
# projects to a full disk, and the 24-hour rate does not. Growth that has
# already stopped is the mirror case, and shows the 6-hour term is needed too.
write_disk_points() {
    python3 "$REPO/tests/disk_trend_points.py" | \
        influx write --org crunchtools --bucket telegraf --token test-admin-token --precision s
}
disk_rule_verdicts() {
    python3 -c '
import base64, json, urllib.request

def call(path, body=None):
    request = urllib.request.Request("http://127.0.0.1:3000" + path,
                                     data=json.dumps(body).encode() if body else None)
    request.add_header("Content-Type", "application/json")
    request.add_header("Authorization", "Basic " + base64.b64encode(b"admin:test-password-123").decode())
    return json.load(urllib.request.urlopen(request, timeout=60))

rule = call("/api/v1/provisioning/alert-rules/disk-time-to-full")
results = call("/api/v1/eval", {"data": rule["data"]})["results"]

def by_path(ref):
    values = {}
    for frame in results[ref]["frames"]:
        for field, column in zip(frame["schema"]["fields"], frame["data"]["values"]):
            if "path" in field.get("labels", {}):
                values[field["labels"]["path"]] = column[-1]
    return values

verdict, slope6, slope24, free = (by_path(ref) for ref in ("C", "RA", "RA24", "RB"))
print(json.dumps({"C": verdict, "hours6": {p: free[p] / slope6[p] for p in slope6 if slope6[p] > 0},
                  "hours24": {p: free[p] / slope24[p] for p in slope24 if slope24[p] > 0}}))
'
}
disk_rule_judges_correctly() {
    disk_rule_verdicts | python3 -c '
import json, sys
seen = json.loads(sys.stdin.read())
verdict, hours6, hours24 = seen["C"], seen["hours6"], seen["hours24"]
assert hours6["/step"] < 168 < hours24["/step"], ("the step must trip only the 6-hour rate", seen)
assert verdict["/step"] == 0, ("a one-off step fired", seen)
assert hours24["/stopped"] < 168 and "/stopped" not in hours6, ("stopped growth must trip only the 24-hour rate", seen)
assert verdict["/stopped"] == 0, ("growth that stopped eight hours ago fired", seen)
assert verdict["/leak"] == 1, ("sustained growth did not fire", seen)
assert verdict["/flat"] == 0, ("a flat disk fired", seen)
'
}
check "synthetic disk points written"            write_disk_points
check "only growth on both windows fires"         disk_rule_judges_correctly

echo "=== Alert webhook (shipped contact point, sample alert) ==="

# A sink stands in for the agent's alert ingress. Grafana's contact-point test
# renders the payload template from the provisioned contact point and POSTs it,
# so this checks the template that ships, not a copy.
python3 "$REPO/tests/webhook_sink.py" 9000 >"$TMP/sink.log" 2>&1 &

send_sample_alert() {
    python3 -c '
import base64, json, re, sys, urllib.request
text = open(sys.argv[1] + "/deploy/grafana/provisioning/alerting/contact-points.yaml").read()
# The payload template is the block scalar under "template: |-"; read it
# without a YAML library, which the image does not carry.
block = re.search(r"template: \|-\n((?:[ ]{14}.*\n|\n)+)", text).group(1)
template = "\n".join(line[14:] for line in block.rstrip("\n").split("\n"))
body = {
    "alert": {
        "labels": {"alertname": "Disk fills within 7 days", "path": "/var"},
        "annotations": {"summary": "/var is full in under 7 days."},
    },
    "integration": {
        "uid": "agent-webhook", "type": "webhook", "version": "v1",
        "settings": {"url": "http://127.0.0.1:9000/alert", "httpMethod": "POST",
                     "payload": {"template": template}},
    },
}
receiver = base64.urlsafe_b64encode(b"agent-webhook").decode().rstrip("=")
url = ("http://127.0.0.1:3000/apis/notifications.alerting.grafana.app/v1beta1"
       f"/namespaces/default/receivers/{receiver}/test")
request = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST")
request.add_header("Content-Type", "application/json")
request.add_header("Authorization", "Basic " + base64.b64encode(b"admin:test-password-123").decode())
reply = json.load(urllib.request.urlopen(request, timeout=30))
assert reply.get("status") == "success", reply
' "$REPO"
}
sink_payload_is_correct() {
    tail -1 "$TMP/sink.log" | python3 -c '
import json, sys
payload = json.loads(sys.stdin.read())
assert sorted(payload) == ["host", "output", "prompt", "service", "state", "type"], sorted(payload)
assert payload["type"] == "TREND" and payload["state"] == "WARNING", payload
assert "NOT AN OUTAGE" in payload["prompt"], payload["prompt"]
assert "Disk fills within 7 days: /var is full in under 7 days." in payload["prompt"], payload["prompt"]
assert payload["service"] == "Disk fills within 7 days", payload["service"]
'
}
contact_point_is_webhook() {
    grafana_api /api/v1/provisioning/contact-points | contains '"type":"webhook"'
}
# The token rides in a header, never in the URL (mcp-trentina #333).
contact_point_sends_bearer() {
    grafana_api /api/v1/provisioning/contact-points | contains '"authorization_scheme":"Bearer"'
}
check "contact point is the agent webhook"   contact_point_is_webhook
check "contact point sends a bearer token"   contact_point_sends_bearer
check "sample alert is delivered"            send_sample_alert
check "delivered payload has the right shape" sink_payload_is_correct

echo "=== MCP server (unit flags; the upstream image itself is not run here) ==="

# The flags are read out of the shipped unit, so a unit edit that breaks this
# parsing fails here rather than silently testing nothing. Starting
# mcp-grafana needs its own container and cannot run in this one.
MCP_UNIT="$REPO/deploy/systemd/mcp-grafana.crunchtools.com.service"
MCP_IMAGE="$(grep -oE 'docker\.io/grafana/mcp-grafana:[0-9.]+' "$MCP_UNIT")"
MCP_ARGS="$(sed -n '/mcp-grafana:[0-9.]* \\$/,/^ExecStop=/p' "$MCP_UNIT" | sed '1d;$d' | tr -d '\\\n')"
check "unit yields an image and read-only flags" \
    bash -c "test -n '$MCP_IMAGE' && echo '$MCP_ARGS' | grep -q -- '--disable-write' && echo '$MCP_ARGS' | grep -q -- '--enabled-tools'"

if [ "$FAIL" -gt 0 ]; then
    for log in influxd receiver grafana sink; do
        echo "--- $log log tail ---"
        tail -40 "$TMP/$log.log" 2>&1 || true
    done
fi

echo
echo "=== $PASS passed, $FAIL failed ==="
echo "versions: $(telegraf --version; influxd version; grafana --version)" | tr '\n' ' '
echo
[ "$FAIL" -eq 0 ]
