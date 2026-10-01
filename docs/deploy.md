# Deploy

Four containers, each with its own directory on the host (constitution XIV).

| Container | Host directory | Published |
|-----------|----------------|-----------|
| `influxdb.crunchtools.com` | `/srv/influxdb.crunchtools.com/{config,data}` | `127.0.0.1:8099` |
| `grafana.crunchtools.com` | `/srv/grafana.crunchtools.com/{config,data}` | `127.0.0.1:8098` |
| `telegraf.crunchtools.com` | `/srv/telegraf.crunchtools.com/config` | none (host network) |
| `mcp-grafana` | `/srv/mcp-grafana.crunchtools.com/config` | `127.0.0.1:8029` |

Inside each `config/`: `etc/` is mounted read-only into the container,
`<name>.env` holds secrets (mode 0600, passed with `--env-file`, never
mounted), and `<name>.service` is a copy of the installed unit.

## First deploy

1. **InfluxDB.** Install `deploy/influxdb/config.yml` to `config/etc/`, write
   `config/influxdb.env` from the example with generated secrets, install and
   start the unit. `ExecStartPost` runs the bootstrap.
2. **Tokens.** Mint the write and read tokens (see [influxdb.md](influxdb.md)).
3. **Telegraf.** Install `telegraf.conf` and a `db-containers.conf` to
   `config/etc/`, put the write token in `config/telegraf.env`, start the unit.
4. **Grafana.** Install `deploy/grafana/` to `config/etc/`, put the read token,
   admin password and alert webhook URL in `config/grafana.env`, start
   the unit.
5. **Proxy.** Add a virtual host forwarding to `127.0.0.1:8098`.
6. **MCP.** Create a Viewer service account in Grafana, put its token in
   `config/mcp-grafana.env`, start the unit, add the backend to the gateway.
7. **Monitoring.** Install `deploy/nagios/tig.cfg` (self-contained: it joins
   the hostgroups and NRPE pool servicegroups itself) and the commands in
   `nrpe-commands.cfg`. The `check_tig_freshness.sh` plugin ships in
   `crunchtools/nagios-agent`.

Units are regular files in `/etc/systemd/system/`. `/srv` is a git repository;
commit exactly the files you changed.

## Upgrades

The `tig` units carry `io.containers.autoupdate=registry` and follow `latest`.
`mcp-grafana` is pinned to a version tag in its unit; bump it deliberately.

## Memory

| Container | Cap |
|-----------|-----|
| influxdb | 768m |
| grafana | 512m |
| telegraf | 384m |
| mcp-grafana | 128m |
