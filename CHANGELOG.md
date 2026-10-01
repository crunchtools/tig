# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/) and this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-09-30

### Added

- One image carrying Telegraf, InfluxDB 2.x and Grafana, with a role
  dispatcher so each container runs exactly one of them.
- `influxdb-bootstrap`: idempotent first-run setup, a 2-year rollup bucket with
  an hourly downsample task, and scoped token minting.
- Telegraf exec inputs: `fd_types.py` (open descriptors by type per process)
  and `ctr_db_status.sh` (MariaDB and PostgreSQL counters over the Podman exec
  socket, no credentials).
- Deploy tree: systemd units, Telegraf and InfluxDB config, Grafana
  provisioning with four dashboards and four trend alert rules.
- A unit for the upstream `grafana/mcp-grafana` server in read-only mode.
- Nagios definitions, including a metrics freshness check.
