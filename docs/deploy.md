# Deploy

Five containers, each with its own directory on the host (constitution XIV).

| Container | Host directory | Published |
|-----------|----------------|-----------|
| `influxdb.crunchtools.com` | `/srv/influxdb.crunchtools.com/{config,data}` | `127.0.0.1:8099` |
| `grafana.crunchtools.com` | `/srv/grafana.crunchtools.com/{config,data}` | `127.0.0.1:8098` |
| `telegraf.crunchtools.com` | `/srv/telegraf.crunchtools.com/config` | none (host network) |
| `telegraf-otlp.crunchtools.com` | `/srv/telegraf-otlp.crunchtools.com/config` | none (`crunchtools` bridge, alias `otlp`, port 4318) |
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
   For OpenRouter spend, add `OPENROUTER_MANAGEMENT_KEY` to `telegraf.env`.
4. **OTLP receiver.** Install `deploy/telegraf-otlp/telegraf.conf` to
   `config/etc/`, write `config/telegraf-otlp.env` from the example (the write
   token and a generated receiver password), start the unit. Point Trentina at
   it with the three settings in the example.
5. **Grafana.** Install `deploy/grafana/` to `config/etc/`, put the read token,
   admin password and alert webhook URL in `config/grafana.env`, start
   the unit.
6. **Proxy.** Add a virtual host forwarding to `127.0.0.1:8098`.
7. **MCP.** Create a Viewer service account in Grafana, put its token in
   `config/mcp-grafana.env`, start the unit, add the backend to the gateway.
8. **Monitoring.** Install `deploy/nagios/tig.cfg` (self-contained: it joins
   the hostgroups and NRPE pool servicegroups itself) and the commands in
   `nrpe-commands.cfg`. The `check_tig_freshness.sh` and `check_tig_trends.sh` plugins ship in
   `crunchtools/nagios-agent`.

Units are regular files in `/etc/systemd/system/`. `/srv` is a git repository;
commit exactly the files you changed.

## Upgrades

The `tig` units carry `io.containers.autoupdate=registry` and follow `latest`.
`mcp-grafana` is pinned to a version tag in its unit; bump it deliberately.

Telegraf is pinned to an exact version in the `Containerfile`, not a minor glob
like InfluxDB and Grafana. Telegraf >= 1.39 fails its entire container list when
podman 5.8.2 reports a gatewayless network's `Gateway` as the literal `<nil>`,
which kills every `docker_container_*` series at once (RT#1567). Do not widen
it to make a build pass; the comment beside the pin has the procedure for
lifting it, and the only evidence that counts is a `telegraf --test` run against
gloval's own socket. CI cannot detect this — a runner has no gatewayless
network, so every telegraf version looks fine there.

`Metrics freshness` covers both the host series and the container series and
reports the worst age of the two. That is deliberate: the check used to ask only
for `system/load1`, so it stayed green through the two days every container
metric was missing.

## Memory

| Container | Cap |
|-----------|-----|
| influxdb | 768m |
| grafana | 1g (`GOMEMLIMIT=600MiB`) |
| telegraf | 384m |
| telegraf-otlp | 128m |
| mcp-grafana | 128m |

Grafana is a Go program and the Go runtime does not read the container's
memory limit: with the default collector setting its heap may grow to twice
the live data before a collection runs. Idle at 150-270 MB, it reached the
512 MB cap and was OOM-killed while a dashboard was open, then fell back to
300 MB on its own once the dashboard was closed. `GOMEMLIMIT` in the unit
makes the runtime collect before the cap.

Size `GOMEMLIMIT` to the working set and `--memory` to the headroom above it,
not the other way round. At 80% of the cap the steady state sits permanently
against Nagios's 85% container-memory warning, which is what 512m with
`GOMEMLIMIT=400MiB` did: 443 MB of 512 MB, warning, with nothing actually
wrong. 1g with `GOMEMLIMIT=600MiB` leaves Go half again as much heap as it was
measured using and still reports around 60%.
