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
    $RUNTIME rm -f tig-test-influxdb tig-test-grafana tig-test-mcp >/dev/null 2>&1 || true
    $RUNTIME network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=== Static tests ==="

check "telegraf runs"            in_image "telegraf --version"
check "influxd runs"             in_image "influxd version"
check "influx CLI runs"          in_image "influx version"
check "grafana runs"             in_image "grafana --version"
check "python3 present"          in_image "python3 --version"
check "dispatcher executable"    in_image "test -x /usr/local/bin/tig"
check "bootstrap executable"     in_image "test -x /usr/local/bin/influxdb-bootstrap"
check "fd walker executable"     in_image "test -x /usr/local/libexec/telegraf/fd_types.py"
check "db collector executable"  in_image "test -x /usr/local/libexec/telegraf/ctr_db_status.py"
check "rollup task shipped"      in_image "test -r /usr/local/share/tig/rollup.flux"
check "influxdb uid is 1501"     in_image "test \"\$(id -u influxdb)\" = 1501"
check "grafana uid is 1502"      in_image "test \"\$(id -u grafana)\" = 1502"
check "unknown role exits 64"    sh -c "$RUNTIME run --rm $IMAGE bogus; test \$? -eq 64"
check "fd walker emits line protocol" \
    sh -c "$RUNTIME run --rm --entrypoint /usr/local/libexec/telegraf/fd_types.py $IMAGE | grep -Eq '^fd_types_total files=[0-9]+i,'"

check "exec input unit tests" \
    $RUNTIME run --rm --entrypoint python3 -v "$REPO/tests:/tests:ro" "$IMAGE" /tests/test_exec_inputs.py

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
        'from(bucket:"telegraf") |> range(start:-5m) |> limit(n:1)' 2>/dev/null | grep -q _value
}
read_token_cannot_write() {
    ! $RUNTIME exec tig-test-influxdb influx write --org crunchtools --bucket telegraf \
        --token "$READ_TOKEN" 'forged value=1' >/dev/null 2>&1
}
freshness_reports_recent_age() {
    local age
    age="$($RUNTIME exec tig-test-influxdb /usr/local/bin/influxdb-freshness)"
    echo "influxdb-freshness printed: '$age'"
    [ "$age" -ge 0 ] && [ "$age" -lt 300 ]
}
check "write token cannot read"                write_token_cannot_read
check "read token cannot write"                read_token_cannot_write
check "freshness helper reports a recent age"  freshness_reports_recent_age
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
        | grep -q "$1"
}
check "rollup script executes"               rollup_script_runs
check "rollup wrote a gauge (mem)"           rollup_bucket_has mem
check "rollup wrote the fd totals"           rollup_bucket_has fd_types_total
check "fd walker data reached influxdb" \
    sh -c "$RUNTIME exec tig-test-influxdb influx query --org crunchtools --token '$READ_TOKEN' \
        'from(bucket:\"telegraf\") |> range(start:-5m) |> filter(fn:(r)=>r._measurement==\"fd_types_total\") |> limit(n:1)' | grep -q fd_types_total"

$RUNTIME run -d --name tig-test-grafana --network "$NET" \
    --user 1502:1502 --tmpfs /var/lib/grafana:exec,uid=1502,gid=1502 \
    -e GF_SECURITY_ADMIN_USER=admin -e GF_SECURITY_ADMIN_PASSWORD=test-password-123 \
    -e INFLUXDB_TOKEN="$READ_TOKEN" -e ALERT_EMAIL=ops@example.com \
    -v "$REPO/deploy/grafana:/etc/grafana:ro" \
    "$IMAGE" grafana >/dev/null

grafana_api() {
    $RUNTIME exec tig-test-grafana curl -sf -u admin:test-password-123 "http://127.0.0.1:3000$1"
}

check "grafana becomes healthy with shipped provisioning" \
    wait_for grafana $RUNTIME exec tig-test-grafana curl -sf http://127.0.0.1:3000/api/health

datasource_provisioned() { grafana_api /api/datasources/uid/influxdb | grep -q '"type":"influxdb"'; }
datasource_healthy()     { grafana_api /api/datasources/uid/influxdb/health | grep -q '"status":"OK"'; }
dashboards_provisioned() { [ "$(grafana_api '/api/search?tag=tig' | grep -o '"uid":"tig-' | wc -l)" -eq 4 ]; }
alert_rules_provisioned() { [ "$(grafana_api /api/v1/provisioning/alert-rules | grep -o '"uid":"' | wc -l)" -ge 4 ]; }

check "datasource provisioned"       datasource_provisioned
# Grafana answers /api/health a few seconds before its bundled InfluxDB plugin
# has been unpacked and started, so these two wait rather than race it.
plugin_backends() { $RUNTIME exec tig-test-grafana ps -e -o args= | grep '/gpx_'; }
influxdb_plugin_running() { plugin_backends | grep -q gpx_grafana_influxdb; }
one_plugin_backend() { [ "$(plugin_backends | grep -c gpx_)" -eq 1 ]; }

check "influxdb plugin backend starts"        wait_for "influxdb plugin" influxdb_plugin_running
check "datasource reaches influxdb"           wait_for "datasource health" datasource_healthy
check "no other plugin backend is running"    one_plugin_backend
check "four dashboards provisioned"  dashboards_provisioned
check "four alert rules provisioned" alert_rules_provisioned

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

SA_ID="$(grafana_post /api/serviceaccounts '{"name":"mcp","role":"Viewer"}' | grep -oE '"id":[0-9]+' | head -1 | cut -d: -f2)"
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
mcp_up() { mcp_call "" "$MCP_INIT" | grep -q '"serverInfo"'; }
check "mcp-grafana starts with the unit's flags" wait_for mcp-grafana mcp_up

MCP_SESSION="$(mcp_call "" "$MCP_INIT" | tr -d '\r' | awk -F': ' 'tolower($1) == "mcp-session-id" {print $2}')"
mcp_call "$MCP_SESSION" '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null || true
MCP_TOOLS="$(mcp_call "$MCP_SESSION" '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')"

mcp_has_tool()     { echo "$MCP_TOOLS" | grep -q "\"name\":\"$1\""; }
mcp_lacks_tool()   { ! mcp_has_tool "$1"; }
mcp_rejects_anon() { mcp_call "" "$MCP_INIT" wrong-token | head -1 | grep -q ' 401'; }
mcp_queries_influx() {
    mcp_call "$MCP_SESSION" '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"query_influxdb","arguments":{"datasourceUid":"influxdb","query":"from(bucket: \"telegraf\") |> range(start: -5m) |> filter(fn: (r) => r._measurement == \"mem\" and r._field == \"available\") |> limit(n: 1)"}}}' \
        | grep -q 'available'
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
