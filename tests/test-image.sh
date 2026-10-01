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
    $RUNTIME rm -f tig-test-influxdb tig-test-grafana >/dev/null 2>&1 || true
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
check "db collector executable"  in_image "test -x /usr/local/libexec/telegraf/ctr_db_status.sh"
check "rollup task shipped"      in_image "test -r /usr/local/share/tig/rollup.flux"
check "influxdb uid is 1501"     in_image "test \"\$(id -u influxdb)\" = 1501"
check "grafana uid is 1502"      in_image "test \"\$(id -u grafana)\" = 1502"
check "unknown role exits 64"    sh -c "$RUNTIME run --rm $IMAGE bogus; test \$? -eq 64"
check "fd walker emits line protocol" \
    sh -c "$RUNTIME run --rm --entrypoint /usr/local/libexec/telegraf/fd_types.py $IMAGE | grep -Eq '^fd_types_total files=[0-9]+i,'"

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
check "fd walker data reached influxdb" \
    sh -c "$RUNTIME exec tig-test-influxdb influx query --org crunchtools --token '$READ_TOKEN' \
        'from(bucket:\"telegraf\") |> range(start:-5m) |> filter(fn:(r)=>r._measurement==\"fd_types_total\") |> limit(n:1)' | grep -q fd_types_total"

$RUNTIME run -d --name tig-test-grafana --network "$NET" \
    --user 1502:1502 --tmpfs /var/lib/grafana:uid=1502,gid=1502 \
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
check "datasource reaches influxdb"  datasource_healthy
check "four dashboards provisioned"  dashboards_provisioned
check "four alert rules provisioned" alert_rules_provisioned

if [ "$FAIL" -gt 0 ]; then
    echo "--- grafana log tail ---"
    $RUNTIME logs --tail 60 tig-test-grafana 2>&1 || true
    echo "--- influxdb log tail ---"
    $RUNTIME logs --tail 30 tig-test-influxdb 2>&1 || true
fi

echo
echo "=== $PASS passed, $FAIL failed ==="
echo "versions: $(in_image 'telegraf --version; influxd version; grafana --version' | tr '\n' ' ')"
[ "$FAIL" -eq 0 ]
