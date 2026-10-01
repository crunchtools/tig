# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/) and this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.1] - 2026-09-30

Found by the first production deploy.

### Fixed

- `influxdb.crunchtools.com.service`: the bootstrap ran in `ExecStartPost`
  before the container existed, failed, and systemd killed the unit in a
  loop. It now waits until the container accepts an exec.
- `telegraf.conf`: removed `perdevice`, `total` and `ignore_protocol_stats`,
  which Telegraf 1.40 rejects or ignores, and moved the exec inputs to array
  syntax. The collector would not start.
- Nagios definitions are self-contained (`hostgroups` and `servicegroups` on
  the objects), so installing them needs no edit to shared files.

### Changed

- Grafana's memory cap is 512 MB; it idles near 260 MB.
- An empty `provisioning/plugins` directory silences a startup error.

### Added

- CI loads the complete `telegraf.conf` and fails on any config error or
  deprecation warning. The filtered run never loaded the docker, net or disk
  inputs, which is how the two bugs above reached production.

## [0.1.0] - 2026-09-30

### Added

- One image carrying Telegraf, InfluxDB 2.x and Grafana, with a role
  dispatcher so each container runs exactly one of them.
- `influxdb-bootstrap`: idempotent first-run setup, a 2-year rollup bucket with
  an hourly downsample task, and scoped token minting.
- Telegraf exec inputs: `fd_types.py` (open descriptors by type per process)
  and `ctr_db_status.py` (MariaDB and PostgreSQL counters over the Podman exec
  socket, no credentials).
- Deploy tree: systemd units, Telegraf and InfluxDB config, Grafana
  provisioning with four dashboards and four trend alert rules.
- A unit for the upstream `grafana/mcp-grafana` server in read-only mode.
- Nagios definitions, including a metrics freshness check.
