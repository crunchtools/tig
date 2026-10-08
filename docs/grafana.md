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
| `disk-time-to-full` | a filesystem fills in under 7 days at both the 6-hour and the 24-hour growth rate |
| `memory-time-to-exhaustion` | available memory runs out in under 24 hours |
| `swap-growth` | swap in use grew more than 1 GiB in 6 hours |
| `container-memory-time-to-limit` | a container above 60% of its limit reaches it in under 12 hours |

Every rule needs three hours of history before it judges a slope, so a
freshly restarted service's start-up ramp is not read as a trend. Rules must
then hold for 30 minutes before notifying.

`disk-time-to-full` needs both windows to agree because disk grows in steps.
An image pull is one step; averaged over six hours it looks like a slope, and
on that window alone any pull over 1/28 of the free space raised the alert.
With the 24-hour rate as well, a step has to exceed 1/7 of the free space.

## Where alerts go

To the on-call agent, as a JSON POST to `ALERT_WEBHOOK_URL` with
`ALERT_WEBHOOK_TOKEN` as a Bearer token (the MCP gateway's alert ingress, the
same door Nagios uses). There is no email path. The payload
carries a `prompt` that tells the agent this is a trend warning and not an
outage: investigate with `query_influxdb`, change nothing, and tell a human
what is growing and when it runs out. Resolved notifications are not sent.

The payload template lives inline in the contact point
(`provisioning/alerting/contact-points.yaml`), so Grafana's contact-point test
renders exactly what a real alert sends.

## Datasource

One InfluxDB datasource, uid `influxdb`, Flux, using the read-only token. Every
dashboard, alert rule and MCP query refers to that uid.
