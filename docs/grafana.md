# Graph and alert: Grafana

Everything is provisioned from files under `deploy/grafana/`; the UI is
read-only for dashboards. To change one, edit the JSON and redeploy.

## Dashboards

| Dashboard | uid | Shows |
|-----------|-----|-------|
| Host | `tig-host` | CPU, load, memory, swap, disk I/O, network, filesystems |
| Containers | `tig-containers` | memory, CPU and network per container, container states |
| Sockets, Pipes and Files | `tig-fds` | descriptors by type, host-wide and per process |
| Databases | `tig-databases` | MariaDB and PostgreSQL connections, throughput, size |

## Trend alerts

Each rule compares a rate of change over the last 6 hours with the headroom
left, and fires on time-to-exhaustion. Level thresholds stay in Nagios.

| Rule | Fires when |
|------|------------|
| `disk-time-to-full` | a filesystem fills in under 7 days at the current growth rate |
| `memory-time-to-exhaustion` | available memory runs out in under 24 hours |
| `swap-growth` | swap in use grew more than 1 GiB in 6 hours |
| `container-memory-time-to-limit` | a container above 60% of its limit reaches it in under 12 hours |

Every rule needs three hours of history before it judges a slope, so a
freshly restarted service's start-up ramp is not read as a trend. Rules must
then hold for 30 minutes before notifying. Notifications go by email to
`ALERT_EMAIL`, through the SMTP relay named in `grafana.env`.

## Datasource

One InfluxDB datasource, uid `influxdb`, Flux, using the read-only token. Every
dashboard, alert rule and MCP query refers to that uid.
