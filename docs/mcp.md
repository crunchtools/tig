# Agent access: MCP

AI agents read the metrics through the upstream
[grafana/mcp-grafana](https://github.com/grafana/mcp-grafana) server, run
unmodified from its published image. It is a fourth container, not a role of
the `tig` image.

```
agent → MCP gateway → mcp-grafana:8029 → grafana:3000 → influxdb:8086
```

## Read-only, three ways

- `--disable-write` removes every tool that creates or changes something.
  `--enable-query` keeps `query_influxdb`.
- The Grafana token belongs to a **Viewer** service account.
- The InfluxDB token Grafana uses can only read the two buckets.

`MCP_GRAFANA_SERVER_TOKEN` makes the server require a bearer token from the
gateway; `--allowed-hosts` restricts the `Host` header to the container name.

## Tested in CI

`tests/test-image.sh` reads the image tag and flags out of
`deploy/systemd/mcp-grafana.crunchtools.com.service`, starts the upstream
server with them against a Grafana running this repo's provisioning, and
asserts: a Viewer service-account token is enough, a wrong caller token gets
401, `query_influxdb` is listed and returns data, and no write tool is listed.
Changing a flag in the unit is therefore tested before it is deployed.

## Tools worth exposing

| Tool | Use |
|------|-----|
| `list_datasources`, `get_datasource` | find the datasource uid (`influxdb`) |
| `query_influxdb` | run a Flux query |
| `search_dashboards`, `get_dashboard_summary`, `get_dashboard_panel_queries`, `get_dashboard_property` | reuse the queries behind a panel |
| `alerting_manage_rules` | list alert rules and their state (read operations only) |
| `generate_deeplink` | hand a human a link to the graph |

## Example query

Host load over the last hour, in 5-minute means:

```flux
from(bucket: "telegraf")
  |> range(start: -1h)
  |> filter(fn: (r) => r._measurement == "system" and r._field == "load1")
  |> aggregateWindow(every: 5m, fn: mean, createEmpty: false)
```

Use `telegraf_rollup` for anything older than 90 days. Measurements and fields
are listed in [telegraf.md](telegraf.md).
