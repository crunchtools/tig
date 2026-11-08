#!/bin/bash
# Smoke test for the tig image.
#
# Usage: RUNTIME=docker IMAGE=tig:test ./tests/test-image.sh
#
# Static: every role's binary and script is present and runnable.
# Runtime: the three roles work together — influxd bootstraps, Telegraf writes
# a point using the shipped telegraf.conf, a Flux query reads it back, and
# Grafana starts with the shipped provisioning (datasource, dashboards, alert
# rules). Grafana refuses to start on invalid provisioning, so a healthy
# Grafana is the test that deploy/grafana/ is loadable.

set -euo pipefail

RUNTIME="${RUNTIME:-podman}"
IMAGE="${IMAGE:-tig:test}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
NET="tig-test-$$"
PASS=0
FAIL=0

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

in_image() {
    $RUNTIME run --rm --entrypoint sh "$IMAGE" -c "$1"
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

cleanup() {
    $RUNTIME rm -f tig-test-influxdb tig-test-grafana tig-test-mcp tig-test-sink tig-test-otlp >/dev/null 2>&1 || true
    $RUNTIME network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=== Static tests ==="

check "telegraf runs"            in_image "telegraf --version"
# RT#1567: telegraf is pinned to an exact version in the Containerfile rather
# than a minor glob, because >= 1.39 fails the entire container list when podman
# 5.8.2 reports a gatewayless network's Gateway as the literal string "<nil>".
# This asserts the PIN, and deliberately claims nothing more: a CI runner has no
# gatewayless network, so a gather test would pass here on a telegraf that
# collects nothing on gloval. Lifting the pin must be verified against gloval's
# real socket -- see the Containerfile comment for the procedure.
check "telegraf is the pinned 1.38.4" \
    in_image "telegraf --version | grep -q 'Telegraf 1\.38\.4'"
check "influxd runs"             in_image "influxd version"
check "influx CLI runs"          in_image "influx version"
check "grafana runs"             in_image "grafana --version"
check "python3 present"          in_image "python3 --version"
check "dispatcher executable"    in_image "test -x /usr/local/bin/tig"
check "bootstrap executable"     in_image "test -x /usr/local/bin/influxdb-bootstrap"
check "fd walker executable"     in_image "test -x /usr/local/libexec/telegraf/fd_types.py"
check "db collector executable"  in_image "test -x /usr/local/libexec/telegraf/ctr_db_status.py"
check "rollup task shipped"      in_image "test -r /usr/local/share/tig/rollup.flux"
check "firing helper executable" in_image "test -x /usr/local/bin/grafana-firing"
check "firing helper fails without grafana" \
    sh -c "$RUNTIME run --rm -e GF_SECURITY_ADMIN_USER=a -e GF_SECURITY_ADMIN_PASSWORD=b --entrypoint /usr/local/bin/grafana-firing $IMAGE; test \$? -eq 1"
check "influxdb uid is 1501"     in_image "test \"\$(id -u influxdb)\" = 1501"
check "grafana uid is 1502"      in_image "test \"\$(id -u grafana)\" = 1502"
check "unknown role exits 64"    sh -c "$RUNTIME run --rm $IMAGE bogus; test \$? -eq 64"
check "fd walker emits line protocol" \
    sh -c "$RUNTIME run --rm --entrypoint /usr/local/libexec/telegraf/fd_types.py $IMAGE | grep -Eq '^fd_types_total files=[0-9]+i,'"

# RT#1567: the exec commands in the shipped config are flat strings, because
# telegraf 1.38.4 rejects the nested ["prog", "arg"] form and fails the whole
# config file on it. That leaves telegraf responsible for splitting "script arg"
# into argv. If it ever stopped doing that, ctr_db_status.py would not run and
# the database counters would disappear with nothing wrong in the data -- the
# same silent shape as the bug this release fixes.
#
# So assert the argument actually arrives, rather than that the config parses:
# point the script at a config naming one container that does not exist, and
# require that name back in the output. If the argument were lost the script
# would read its default config instead and never mention it. A command that
# telegraf cannot split fails with "fork/exec ...: no such file or directory"
# and emits nothing at all.
exec_command_string_reaches_argv() {
    local dir out
    dir="$(mktemp -d)"
    chmod 755 "$dir"
    printf 'probe-not-a-container mariadb\n' > "$dir/db-probe.conf"
    cat > "$dir/probe.conf" <<'PROBE'
[agent]
  interval = "10s"
  omit_hostname = true
[[inputs.exec]]
  commands = ["/usr/local/libexec/telegraf/ctr_db_status.py /etc/telegraf/db-probe.conf"]
  timeout = "20s"
  data_format = "influx"
PROBE
    chmod 644 "$dir/db-probe.conf" "$dir/probe.conf"
    # ,Z relabels for SELinux: these fixtures are created outside the repo, so
    # without it the container cannot read them and the test fails for the wrong
    # reason. Both podman and docker accept the flag; it is a no-op where
    # SELinux is not enforcing.
    out="$($RUNTIME run --rm \
        -v "$dir/db-probe.conf:/etc/telegraf/db-probe.conf:ro,Z" \
        -v "$dir/probe.conf:/etc/telegraf/probe.conf:ro,Z" \
        --entrypoint telegraf "$IMAGE" --config /etc/telegraf/probe.conf --test 2>&1)"
    rm -rf "$dir"
    contains "db_collector,container=probe-not-a-container up=0i" <<<"$out" && return 0
    # Report what telegraf actually said. Without this the assertion fails with
    # no output and the next person has to re-derive the cause from nothing,
    # which is how the first version of this test cost an hour: it passed
    # standalone and failed in the suite, and the SELinux denial that explained
    # it was sitting unread in this variable.
    echo "telegraf output was:"
    printf '%s\n' "$out"
    return 1
}
check "exec command string is split into argv" exec_command_string_reaches_argv

echo "=== Runtime tests ==="

$RUNTIME network create "$NET" >/dev/null

$RUNTIME run -d --name tig-test-influxdb --network "$NET" --network-alias influxdb \
    --user 1501:1501 --tmpfs /var/lib/influxdb2:uid=1501,gid=1501 \
    -e HOME=/var/lib/influxdb2 \
    -e INFLUXDB_INIT_USERNAME=admin -e INFLUXDB_INIT_PASSWORD=test-password-123 \
    -e INFLUXDB_INIT_ORG=crunchtools -e INFLUXDB_INIT_BUCKET=telegraf \
    -e INFLUXDB_INIT_ADMIN_TOKEN=test-admin-token \
    -v "$REPO/deploy/influxdb/config.yml:/etc/influxdb/config.yml:ro" \
    "$IMAGE" influxd >/dev/null

check "influxd becomes healthy" \
    wait_for influxd $RUNTIME exec tig-test-influxdb curl -sf http://127.0.0.1:8086/health
check "bootstrap succeeds" \
    $RUNTIME exec tig-test-influxdb /usr/local/bin/influxdb-bootstrap
check "bootstrap is idempotent" \
    $RUNTIME exec tig-test-influxdb /usr/local/bin/influxdb-bootstrap
check "rollup bucket exists" \
    sh -c "$RUNTIME exec tig-test-influxdb influx bucket list --org crunchtools --token test-admin-token | grep -q telegraf_rollup"
check "rollup task exists" \
    sh -c "$RUNTIME exec tig-test-influxdb influx task list --org crunchtools --token test-admin-token | grep -q rollup-1h"

WRITE_TOKEN="$($RUNTIME exec tig-test-influxdb /usr/local/bin/influxdb-bootstrap token write)"
READ_TOKEN="$($RUNTIME exec tig-test-influxdb /usr/local/bin/influxdb-bootstrap token read)"
check "write token minted" test -n "$WRITE_TOKEN"
check "read token minted"  test -n "$READ_TOKEN"

# Load the WHOLE shipped config, every plugin. An option a plugin no longer
# accepts is fatal at startup, and a deprecated one will be: the filtered run
# below never loads the docker, net or disk inputs, so it cannot catch either.
# Gather errors (no Podman socket here) are expected and ignored; only what
# Telegraf says about the config itself matters.
full_config_loads_cleanly() {
    local output
    output="$($RUNTIME run --rm \
        -e INFLUX_URL=http://influxdb:8086 -e INFLUX_ORG=crunchtools \
        -e INFLUX_BUCKET=telegraf -e INFLUX_TOKEN=unused \
        -v "$REPO/deploy/telegraf/telegraf.conf:/etc/telegraf/telegraf.conf:ro" \
        "$IMAGE" telegraf --test 2>&1 || true)"
    if grep -E 'loading config file .* failed|DeprecationWarning' <<<"$output"; then
        return 1
    fi
    grep -q '^> mem,' <<<"$output"
}
check "full telegraf config loads with no errors or deprecations" full_config_loads_cleanly

# The shipped config, restricted to inputs that need no host access.
check "telegraf writes with the shipped config" \
    $RUNTIME run --rm --network "$NET" \
        -e INFLUX_URL=http://influxdb:8086 -e INFLUX_ORG=crunchtools \
        -e INFLUX_BUCKET=telegraf -e INFLUX_TOKEN="$WRITE_TOKEN" \
        -v "$REPO/deploy/telegraf/telegraf.conf:/etc/telegraf/telegraf.conf:ro" \
        "$IMAGE" telegraf --input-filter cpu:mem:swap:system:exec --once

check "read token can query the point back" \
    sh -c "$RUNTIME exec tig-test-influxdb influx query --org crunchtools --token '$READ_TOKEN' \
        'from(bucket:\"telegraf\") |> range(start:-5m) |> filter(fn:(r)=>r._measurement==\"mem\") |> limit(n:1)' | grep -q available"
# The tokens are only worth minting if they are actually scoped.
write_token_cannot_read() {
    ! $RUNTIME exec tig-test-influxdb influx query --org crunchtools --token "$WRITE_TOKEN" \
        'from(bucket:"telegraf") |> range(start:-5m) |> limit(n:1)' 2>/dev/null | contains _value
}
read_token_cannot_write() {
    ! $RUNTIME exec tig-test-influxdb influx write --org crunchtools --bucket telegraf \
        --token "$READ_TOKEN" 'forged value=1' >/dev/null 2>&1
}
# RT#1567: influxdb-freshness now requires the CONTAINER pipeline as well as
# system/load1. inputs.docker cannot gather in here (no Podman socket), so seed
# one docker_container_mem point to stand for a healthy container pipeline.
$RUNTIME exec tig-test-influxdb influx write --org crunchtools --bucket telegraf \
    --token test-admin-token 'docker_container_mem,container_name=seed usage=1i' >/dev/null

freshness_reports_recent_age() {
    local age
    age="$($RUNTIME exec tig-test-influxdb /usr/local/bin/influxdb-freshness)"
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
    [ "$($RUNTIME exec tig-test-influxdb /usr/local/bin/influxdb-freshness \
        system:load1 docker_container_mem:nosuchfield)" = "-1" ]
}
check "write token cannot read"                write_token_cannot_read
check "read token cannot write"                read_token_cannot_write
check "freshness helper reports a recent age"  freshness_reports_recent_age
check "freshness requires the container pipeline, not just the host" \
    freshness_requires_the_container_pipeline
# Nothing has been rolled up yet, so the rollup bucket is the no-data case.
freshness_reports_no_data() {
    [ "$($RUNTIME exec -e INFLUXDB_INIT_BUCKET=telegraf_rollup tig-test-influxdb /usr/local/bin/influxdb-freshness)" = "-1" ]
}
check "freshness helper reports -1 with no data" freshness_reports_no_data

# The task only fires on the hour, so run its script as a query. That executes
# the real Flux — the import, both aggregations and the write — against the
# points Telegraf just stored.
rollup_script_runs() {
    $RUNTIME exec -e INFLUX_HOST=http://127.0.0.1:8086 -e INFLUX_TOKEN=test-admin-token tig-test-influxdb \
        influx query --org crunchtools --file /usr/local/share/tig/rollup.flux >/dev/null
}
rollup_bucket_has() {
    $RUNTIME exec tig-test-influxdb influx query --org crunchtools --token "$READ_TOKEN" \
        "from(bucket:\"telegraf_rollup\") |> range(start:-2h, stop: 2h) |> filter(fn:(r)=>r._measurement==\"$1\") |> limit(n:1)" \
        | contains "$1"
}
check "rollup script executes"               rollup_script_runs
check "rollup wrote a gauge (mem)"           rollup_bucket_has mem
check "rollup wrote the fd totals"           rollup_bucket_has fd_types_total
check "fd walker data reached influxdb" \
    sh -c "$RUNTIME exec tig-test-influxdb influx query --org crunchtools --token '$READ_TOKEN' \
        'from(bucket:\"telegraf\") |> range(start:-5m) |> filter(fn:(r)=>r._measurement==\"fd_types_total\") |> limit(n:1)' | grep -q fd_types_total"

echo "=== OTLP receiver (shipped telegraf-otlp config, a payload from Trentina's exporter) ==="

# tests/fixtures/otlp-trentina.json is what trentina's telemetry.otlp_payload
# produces for five calls; the receiver must turn each span into one point.
$RUNTIME run -d --name tig-test-otlp --network "$NET" --network-alias otlp \
    -e INFLUX_URL=http://influxdb:8086 -e INFLUX_ORG=crunchtools \
    -e INFLUX_BUCKET=telegraf -e INFLUX_TOKEN="$WRITE_TOKEN" \
    -e OTLP_USERNAME=trentina -e OTLP_PASSWORD=otlp-test-password \
    -v "$REPO/deploy/telegraf-otlp/telegraf.conf:/etc/telegraf/telegraf.conf:ro" \
    "$IMAGE" telegraf >/dev/null

otlp_post() {
    $RUNTIME run --rm --network "$NET" -v "$REPO/tests/fixtures:/fixtures:ro" --entrypoint curl "$IMAGE" \
        -s -o /dev/null -w '%{http_code}' -m 10 "$@" \
        -H 'Content-Type: application/json' --data-binary @/fixtures/otlp-trentina.json \
        http://otlp:4318/v1/traces
}
otlp_up() { [ "$(otlp_post -u trentina:otlp-test-password)" = 204 ]; }
otlp_refuses_without_auth() { [ "$(otlp_post)" = 401 ]; }
otlp_refuses_wrong_auth() { [ "$(otlp_post -u trentina:wrong)" = 401 ]; }
otlp_points_count() {
    $RUNTIME exec tig-test-influxdb influx query --org crunchtools --token "$READ_TOKEN" --raw \
        'from(bucket:"telegraf") |> range(start: 2026-11-01T00:00:00Z) |> filter(fn:(r)=>r._measurement=="trentina_calls" and r._field=="duration_ms") |> group() |> count()' \
        | tr -d '\r' | grep -oE ',[0-9]+$' | tr -d ,
}
otlp_points_arrived() { [ "$(otlp_points_count)" = 5 ]; }
otlp_blocked_call_tagged() {
    $RUNTIME exec tig-test-influxdb influx query --org crunchtools --token "$READ_TOKEN" --raw \
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
    python3 - "$REPO/deploy/grafana/dashboards/trentina.json" <<'PY' > "$REPO/.trentina-queries.txt"
import json, sys
for panel in json.load(open(sys.argv[1]))["panels"]:
    for target in panel["targets"]:
        print(json.dumps({"title": panel["title"], "query": target["query"]}))
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
        if ! out="$($RUNTIME exec tig-test-influxdb influx query --org crunchtools --token "$READ_TOKEN" --raw "$flux" 2>&1)" \
            || [ "$(grep -v '^#' <<<"$out" | grep -c '^,')" -lt 2 ]; then
            echo "panel '$title' failed: $(head -c 300 <<<"$out")"
            failed=1
        fi
    done < "$REPO/.trentina-queries.txt"
    rm -f "$REPO/.trentina-queries.txt"
    return $failed
}
check "every Trentina dashboard query returns rows" dashboard_queries_run

$RUNTIME run -d --name tig-test-grafana --network "$NET" \
    --user 1502:1502 --tmpfs /var/lib/grafana:exec,uid=1502,gid=1502 \
    -e GF_SECURITY_ADMIN_USER=admin -e GF_SECURITY_ADMIN_PASSWORD=test-password-123 \
    -e INFLUXDB_TOKEN="$READ_TOKEN" -e ALERT_WEBHOOK_URL=http://alert-sink:9000/alert \
    -e ALERT_WEBHOOK_TOKEN=sink-token \
    -v "$REPO/deploy/grafana:/etc/grafana:ro" \
    "$IMAGE" grafana >/dev/null

grafana_api() {
    $RUNTIME exec tig-test-grafana curl -sf -u admin:test-password-123 "http://127.0.0.1:3000$1"
}

check "grafana becomes healthy with shipped provisioning" \
    wait_for grafana $RUNTIME exec tig-test-grafana curl -sf http://127.0.0.1:3000/api/health

datasource_provisioned() { grafana_api /api/datasources/uid/influxdb | contains '"type":"influxdb"'; }
datasource_healthy()     { grafana_api /api/datasources/uid/influxdb/health | contains '"status":"OK"'; }
dashboards_provisioned() { [ "$(grafana_api '/api/search?tag=tig' | grep -o '"uid":"tig-' | wc -l)" -eq 5 ]; }
alert_rules_provisioned() { [ "$(grafana_api /api/v1/provisioning/alert-rules | grep -o '"uid":"' | wc -l)" -ge 4 ]; }

check "datasource provisioned"       datasource_provisioned
# Grafana answers /api/health a few seconds before its bundled InfluxDB plugin
# has been unpacked and started, so these two wait rather than race it.
plugin_backends() { $RUNTIME exec tig-test-grafana ps -e -o args= | grep '/gpx_'; }
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
firing_helper_reads_grafana() { $RUNTIME exec tig-test-grafana /usr/local/bin/grafana-firing; }
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
    python3 "$REPO/tests/disk_trend_points.py" | $RUNTIME exec -i tig-test-influxdb \
        influx write --org crunchtools --bucket telegraf --token test-admin-token --precision s
}
disk_rule_verdicts() {
    $RUNTIME run --rm --network "$NET" --entrypoint python3 "$IMAGE" -c '
import base64, json, urllib.request

def call(path, body=None):
    request = urllib.request.Request("http://tig-test-grafana:3000" + path,
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
$RUNTIME run -d --name tig-test-sink --network "$NET" --network-alias alert-sink \
    -v "$REPO/tests:/tests:ro" --entrypoint python3 "$IMAGE" /tests/webhook_sink.py 9000 >/dev/null

send_sample_alert() {
    $RUNTIME run --rm --network "$NET" -v "$REPO:/repo:ro" --entrypoint python3 "$IMAGE" -c '
import base64, json, re, urllib.request
text = open("/repo/deploy/grafana/provisioning/alerting/contact-points.yaml").read()
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
        "settings": {"url": "http://alert-sink:9000/alert", "httpMethod": "POST",
                     "payload": {"template": template}},
    },
}
receiver = base64.urlsafe_b64encode(b"agent-webhook").decode().rstrip("=")
url = ("http://tig-test-grafana:3000/apis/notifications.alerting.grafana.app/v1beta1"
       f"/namespaces/default/receivers/{receiver}/test")
request = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST")
request.add_header("Content-Type", "application/json")
request.add_header("Authorization", "Basic " + base64.b64encode(b"admin:test-password-123").decode())
reply = json.load(urllib.request.urlopen(request, timeout=30))
assert reply.get("status") == "success", reply
'
}
sink_payload_is_correct() {
    $RUNTIME logs tig-test-sink 2>/dev/null | tail -1 | python3 -c '
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

echo "=== MCP server (upstream image, flags from the shipped unit) ==="

# The image and its arguments are read out of the unit, so this exercises the
# flags that actually get deployed rather than a copy of them.
MCP_UNIT="$REPO/deploy/systemd/mcp-grafana.crunchtools.com.service"
MCP_IMAGE="$(grep -oE 'docker\.io/grafana/mcp-grafana:[0-9.]+' "$MCP_UNIT")"
MCP_ARGS="$(sed -n '/mcp-grafana:[0-9.]* \\$/,/^ExecStop=/p' "$MCP_UNIT" | sed '1d;$d' | tr -d '\\\n')"

# A unit edit that breaks this parsing must fail here, not silently test nothing.
check "unit yields an image and read-only flags" \
    sh -c "test -n '$MCP_IMAGE' && echo '$MCP_ARGS' | grep -q -- '--disable-write' && echo '$MCP_ARGS' | grep -q -- '--enabled-tools'"

grafana_post() {
    $RUNTIME exec tig-test-grafana curl -sf -u admin:test-password-123 \
        -H 'Content-Type: application/json' -X POST "http://127.0.0.1:3000$1" -d "$2"
}

SA_ID="$(grafana_post /api/serviceaccounts '{"name":"mcp","role":"Viewer"}' | grep -oE '"id":[0-9]+' | sed -n 1p | cut -d: -f2)"
SA_TOKEN="$(grafana_post "/api/serviceaccounts/$SA_ID/tokens" '{"name":"mcp"}' | grep -oE '"key":"[^"]+"' | cut -d'"' -f4)"
check "viewer service account token minted" test -n "$SA_TOKEN"

# shellcheck disable=SC2086  # MCP_ARGS is a flag list and must word-split
$RUNTIME run -d --name tig-test-mcp --network "$NET" --network-alias mcp-grafana \
    -e GRAFANA_URL=http://tig-test-grafana:3000 \
    -e GRAFANA_SERVICE_ACCOUNT_TOKEN="$SA_TOKEN" \
    -e MCP_GRAFANA_SERVER_TOKEN=test-caller-token \
    "$MCP_IMAGE" $MCP_ARGS >/dev/null

# One JSON-RPC call to the MCP endpoint from inside the test network, so the
# Host header is the container name the unit's --allowed-hosts expects.
mcp_call() {
    local session="$1" body="$2" auth="${3:-test-caller-token}"
    $RUNTIME run --rm --network "$NET" --entrypoint curl "$IMAGE" -s -i -m 20 \
        -X POST http://mcp-grafana:8029/mcp \
        -H "Authorization: Bearer $auth" \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json, text/event-stream' \
        ${session:+-H "Mcp-Session-Id: $session"} \
        -d "$body"
}

MCP_INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"tig-test","version":"0"}}}'
mcp_up() { mcp_call "" "$MCP_INIT" | contains '"serverInfo"'; }
check "mcp-grafana starts with the unit's flags" wait_for mcp-grafana mcp_up

MCP_SESSION="$(mcp_call "" "$MCP_INIT" | tr -d '\r' | awk -F': ' 'tolower($1) == "mcp-session-id" {print $2}')"
mcp_call "$MCP_SESSION" '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null || true
MCP_TOOLS="$(mcp_call "$MCP_SESSION" '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')"

mcp_has_tool()     { grep -q "\"name\":\"$1\"" <<<"$MCP_TOOLS"; }
mcp_lacks_tool()   { ! mcp_has_tool "$1"; }
mcp_rejects_anon() { mcp_call "" "$MCP_INIT" wrong-token | sed -n 1p | contains ' 401'; }
mcp_queries_influx() {
    mcp_call "$MCP_SESSION" '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"query_influxdb","arguments":{"datasourceUid":"influxdb","query":"from(bucket: \"telegraf\") |> range(start: -5m) |> filter(fn: (r) => r._measurement == \"mem\" and r._field == \"available\") |> limit(n: 1)"}}}' \
        | contains 'available'
}

check "query_influxdb is exposed"            mcp_has_tool query_influxdb
check "list_datasources is exposed"          mcp_has_tool list_datasources
check "search_dashboards is exposed"         mcp_has_tool search_dashboards
check "update_dashboard is not exposed"      mcp_lacks_tool update_dashboard
check "create_annotation is not exposed"     mcp_lacks_tool create_annotation
check "wrong caller token is rejected"       mcp_rejects_anon
check "a Flux query returns data end to end" mcp_queries_influx

if [ "$FAIL" -gt 0 ]; then
    echo "--- grafana log tail ---"
    $RUNTIME logs --tail 60 tig-test-grafana 2>&1 || true
    echo "--- mcp-grafana log tail ---"
    $RUNTIME logs --tail 40 tig-test-mcp 2>&1 || true
    echo "--- mcp tools/list response ---"
    echo "${MCP_TOOLS:-}" | cut -c1-2000
    echo "--- rollup script output ---"
    $RUNTIME exec -e INFLUX_HOST=http://127.0.0.1:8086 -e INFLUX_TOKEN=test-admin-token tig-test-influxdb \
        influx query --org crunchtools --file /usr/local/share/tig/rollup.flux 2>&1 | tail -30 || true
    echo "--- measurements in the rollup bucket ---"
    $RUNTIME exec -e INFLUX_HOST=http://127.0.0.1:8086 -e INFLUX_TOKEN=test-admin-token tig-test-influxdb \
        influx query --org crunchtools \
        'from(bucket:"telegraf_rollup") |> range(start:-2h, stop:2h) |> keep(columns:["_measurement"]) |> group() |> distinct(column:"_measurement")' 2>&1 || true
    echo "--- influxdb log tail ---"
    $RUNTIME logs --tail 30 tig-test-influxdb 2>&1 || true
fi

echo
echo "=== $PASS passed, $FAIL failed ==="
echo "versions: $(in_image 'telegraf --version; influxd version; grafana --version' | tr '\n' ' ')"
[ "$FAIL" -eq 0 ]
