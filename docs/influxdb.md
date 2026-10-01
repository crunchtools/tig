# Store: InfluxDB 2.x

InfluxDB 2.x, not 3 Core: v3 Core has no Flux and no compactor, and the point
of this stack is trend graphs over months.

## Buckets

| Bucket | Retention | Contents |
|--------|-----------|----------|
| `telegraf` | 90 days | raw 30-second data |
| `telegraf_rollup` | 2 years | hourly: mean for gauges, last for counters |

The `rollup-1h` task (`rootfs/usr/local/share/tig/rollup.flux`) fills the
second from the first.

## Bootstrap

The unit runs `influxdb-bootstrap` after every start. On the first start it
performs the initial setup from `influxdb.env`; on every start it re-creates
the rollup bucket and task if they are missing. It never changes anything that
already exists.

## Tokens

```bash
podman exec influxdb.crunchtools.com influxdb-bootstrap token write   # Telegraf
podman exec influxdb.crunchtools.com influxdb-bootstrap token read    # Grafana
```

The write token can only write `telegraf`. The read token can only read the two
buckets. The admin token stays in `influxdb.env`.

## Memory

The container is capped at 768 MB. `deploy/influxdb/config.yml` limits the
write cache to 256 MiB, queries to two at a time at 128 MiB each, and
compactions to one at a time;
`GOMEMLIMIT` in the env file keeps the Go runtime under the cap.
