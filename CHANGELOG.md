# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/) and this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- Constitution is now a v1.18.0 manifest: it holds only what is specific to
  this repo; fleet and profile rules apply by reference.
- Constitution validation is pinned to the inherited release via
  `.github/workflows/constitution.yml`.
- Dependabot auto-merges GitHub Actions minor and patch updates.

### Fixed

- `disk-time-to-full` no longer fires on a single image pull. It projected
  from the 6-hour growth rate alone, so a one-off step over 1/28 of the free
  space (about 2.3 GB on lotor) read as a slope that filled the disk within 7
  days. The 24-hour rate must now agree, which raises the step it takes to
  1/7 of the free space. Over one week of lotor data the old condition held
  in 90 half-hour windows and the new one in at most 9, all in one day of
  ~11 GB net growth.

## [0.3.0] - 2026-10-01

### Changed

- The alert contact point sends its token as `Authorization: Bearer` from
  `ALERT_WEBHOOK_TOKEN`; `ALERT_WEBHOOK_URL` no longer carries it. Every
  access log on the way records the URL (mcp-trentina #333). Upgrade: set
  `ALERT_WEBHOOK_URL` to the bare `/alert` endpoint and add
  `ALERT_WEBHOOK_TOKEN`; the gateway needs mcp-trentina 0.52.0.

## [0.2.2] - 2026-10-01

### Fixed

- Grafana was OOM-killed at its 512 MB cap with a dashboard open. The Go
  runtime does not see the container limit and let the heap grow to the cap;
  the same process fell back to 300 MB once the dashboard closed. The unit
  sets `GOMEMLIMIT=400MiB` so the runtime collects first.
- The per-process panels of the Sockets, Pipes and Files dashboard ask for at
  most 300 points per series, about a quarter of what they pulled over 24
  hours.

## [0.2.1] - 2026-10-01

### Fixed

- The per-process panels of the Sockets, Pipes and Files dashboard failed with
  `max series limit exceeded`. `fd_types.py` emitted a record for every kernel
  thread, and kworkers rename themselves per job, so one host produced 1252
  process names in a day against Grafana's cap of 1000 series per query. The
  collector now skips a process holding no descriptors, and the panels drop
  zero-valued points so the names already stored no longer count.
  `fd_types_total.procs` counts processes that hold descriptors.
- Compiled `__pycache__` files are no longer tracked or copied into the image.

## [0.2.0] - 2026-10-01

### Changed

- Trend alerts are delivered by webhook to the on-call agent's alert ingress
  (`ALERT_WEBHOOK_URL`) instead of by email. The deploy host has no working
  outbound mail and its Nagios alerts already go to the agent; the email
  contact point in 0.1.x could never deliver. The payload tells the agent it
  is a trend warning: investigate, change nothing, tell a human.
- `grafana.env` drops the `GF_SMTP_*` settings and `ALERT_EMAIL`.

### Added

- CI posts a sample alert through the shipped contact point to a sink and
  asserts the payload is valid JSON with the expected fields.

## [0.1.2] - 2026-09-30

### Fixed

- Trend alert rules require three hours of history (six slope samples)
  before evaluating. Two rules went pending within twenty minutes of the
  first deploy, reading the stack's own start-up as a trend.
- Telegraf's memory cap is 384 MB. The process uses about 50 MB, but page
  and dentry cache from walking `/proc` and `/hostfs` count toward the
  container's usage and put it at 87% of the old 192 MB cap.

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
