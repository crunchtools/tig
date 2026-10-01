# tig

Telegraf, InfluxDB 2.x and Grafana in one UBI 10 image, run as three
containers. It adds graphs and rate-of-change alerting next to Nagios: Nagios
says a threshold was crossed, this says how fast you are approaching it.

## Capabilities

1. **[Collect](docs/telegraf.md)** — host CPU, memory, disk and network;
   per-container CPU and memory from the Podman socket; open file descriptors
   by type; database counters from inside other containers.
2. **[Store](docs/influxdb.md)** — 90 days of raw data, 2 years of hourly
   rollups, bootstrapped on first start.
3. **[Graph and alert](docs/grafana.md)** — four provisioned dashboards and
   four trend alert rules that fire on time-to-exhaustion.
4. **[Agent access](docs/mcp.md)** — read-only MCP access for AI agents through
   the upstream Grafana MCP server.
5. **[Deploy](docs/deploy.md)** — units, host directory layout, tokens and
   monitoring.

## Quick start

```bash
podman network create tig
podman run -d --name influxdb --network tig --user 1501:1501 \
    -e HOME=/var/lib/influxdb2 -e INFLUXDB_INIT_USERNAME=admin \
    -e INFLUXDB_INIT_PASSWORD=change-me-now -e INFLUXDB_INIT_ORG=crunchtools \
    -e INFLUXDB_INIT_ADMIN_TOKEN=change-me-too \
    -v tig-influxdb:/var/lib/influxdb2 \
    -v ./deploy/influxdb/config.yml:/etc/influxdb/config.yml:ro,Z \
    quay.io/crunchtools/tig influxd
podman exec influxdb influxdb-bootstrap
podman exec influxdb influxdb-bootstrap token write    # for Telegraf
podman exec influxdb influxdb-bootstrap token read     # for Grafana
```

The same image runs the other two roles: `quay.io/crunchtools/tig grafana` and
`quay.io/crunchtools/tig telegraf`. See [docs/deploy.md](docs/deploy.md) for
the production units.

## Documentation

| Page | What it covers |
|------|----------------|
| [docs/telegraf.md](docs/telegraf.md) | Inputs, measurements, host access |
| [docs/influxdb.md](docs/influxdb.md) | Buckets, retention, rollup, tokens |
| [docs/grafana.md](docs/grafana.md) | Dashboards, alert rules, provisioning |
| [docs/mcp.md](docs/mcp.md) | MCP server flags, tools, example queries |
| [docs/deploy.md](docs/deploy.md) | Host layout, first deploy, monitoring |

## Development

Images are built only by GitHub Actions. A pull request builds the image and
runs `tests/test-image.sh` against it; a merge to `main` pushes to Quay and
GHCR. Gourmand and Gatehouse run as pre-commit hooks and in CI:

```bash
pre-commit install
```

## License

AGPL-3.0-or-later. See [LICENSE](LICENSE). Telegraf, InfluxDB and Grafana are
distributed under their own licenses.
