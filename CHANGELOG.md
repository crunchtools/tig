# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/) and this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.8.1] - 2026-11-11

### Changed

- The Trentina dashboard is now crunchtools/trentina's portable copy
  (`contrib/grafana/trentina-dashboard.json`, trentina#770): a tooltip on
  every panel, the data source and bucket as dashboard variables, and stat
  panels that no longer turn red above 80. Edit it in trentina and copy it
  here; `tests/test-image.sh` checks the copy's marker.

## [0.8.0] - 2026-11-09

### Changed

- **The two Telegrafs are named for what they do.** `telegraf.crunchtools.com`
  is now `telegraf-host.crunchtools.com` (gathers metrics from the host) and
  `telegraf-otlp.crunchtools.com` is now `telegraf-receiver.crunchtools.com`
  (receives what services send it; network alias `telegraf-receiver`, was
  `otlp`). Units, `/srv` directories, env files, `deploy/` directories, Nagios
  hosts (`ctr-telegraf-host`, `ctr-telegraf-receiver`) and NRPE commands
  follow. Container metrics are tagged by container name, so the Containers
  dashboard shows the new name from the switch on. Operators: move the `/srv`
  directories and rename the env files; point `TRENTINA_OTLP_ENDPOINT` at
  `http://telegraf-receiver:4318`.

## [0.7.0] - 2026-11-08

### Changed

- **`TELEGRAF_VERSION` is a minor glob again, not an exact pin (RT #1598).**
  The pin existed because telegraf >= 1.39 parses a container's `Gateway`
  through `netip.ParseAddr` and discards the entire container list on one bad
  value, and podman 5.8.2's Docker-compat `/containers/json` rendered a
  gatewayless network's gateway as the literal string `<nil>`. Gloval had five
  such networks, so all 61 containers lost metrics while the collector still
  reported healthy (RT #1567). RT #1598 gave those networks explicit gateways;
  the compat response now carries zero `<nil>`, so no telegraf version is
  excluded any more. The version assertion in `tests/test-image.sh` and the
  constitution deviation are removed with the pin, since all three described the
  same constraint. Weekly rebuilds pick up telegraf patch releases again, which
  means a telegraf CVE no longer needs a hand edit. Upstream, unchanged and not
  waited on: containers/podman#30149.
- **`inputs.exec` commands are nested `["prog", "arg"]` arrays again.** The flat
  `"prog arg"` string was forced by the 1.38.4 pin, which rejected arrays. With
  the pin gone the array is the only correct form: telegraf deprecated the
  string in 1.39.0 and removes it in 1.45.0, and on 1.40.3 every flat command
  logs a deprecation warning — which the config-load test, correctly, fails on.
  The argv assertion in `tests/test-image.sh` is kept and retargeted: it still
  proves `ctr_db_status.py` receives its config path, which is the part that
  would fail silently.
### Removed

- The OpenRouter spend collector (`openrouter_usage.py`), its exec input and
  the seven spend panels on the Trentina dashboard. Spend tracking is not
  wanted, and the collector needed an OpenRouter management key, the one
  credential here that can create and delete keys. Never deployed: the host
  telegraf.conf on gloval did not carry the stanza.

## [0.6.0] - 2026-11-08

### Added

- **A Trentina dashboard: gateway traffic and OpenRouter spend in one place
  (RT #1544).** Calls by outcome, profile and backend; detections by layer;
  the most-flagged tools; p50 and p95 duration; egress tunnels; failed model
  calls; and OpenRouter spend and tokens per day by model and by agent key,
  today's spend and the credit balance.
- `telegraf-otlp`: a second Telegraf on the `crunchtools` bridge that receives
  Trentina's call traces as OTLP/HTTP JSON and writes `trentina_calls`. Its
  own unit, env example and Nagios checks.
- `openrouter_usage.py`, an exec collector for OpenRouter's analytics, keys
  and credits APIs, run every 15 minutes from the host Telegraf. It needs
  `OPENROUTER_MANAGEMENT_KEY` and reports `openrouter_collector up=0` without
  it.

## [0.5.0] - 2026-11-08

### Fixed

- Telegraf collects per-container metrics again. It is pinned to an exact
  1.38.4 instead of the `1.40.*` glob, because every telegraf from 1.39.0
  onward fails its whole container list on gloval and collects nothing at all.
  podman 5.8.2's Docker-compatible `/containers/json` returns the literal
  string `<nil>` as `NetworkSettings.Networks.<net>.Gateway` for a network with
  no gateway — five of gloval's networks are gatewayless, giving ten such values
  in one response — and telegraf >= 1.39 parses that field through
  `netip.ParseAddr`, so one bad value discards the entire list. Measured on
  gloval's socket: 1.38.4 collects all 61 series; 1.39.0, 1.39.3, 1.40.0,
  1.40.1, 1.40.2 and 1.40.3 collect none. It is not about `--network host`,
  which was the first theory and is wrong. RT#1567.

  Container metrics had been dead since 2026-11-06, which is why trentina's
  six-hour climb to its memory cap was invisible.

- The two `inputs.exec` stanzas in `deploy/telegraf/telegraf.conf` now give
  `commands` as single strings rather than nested `["prog", "arg"]` arrays. The
  nested form is only accepted by telegraf >= 1.39; on 1.38.4 it fails the whole
  config file with `cannot unmarshal TOML array into string`, which takes every
  input down rather than just those two. Verified to load identically on 1.38.4
  and 1.40.3, so it stays correct when the pin is lifted. Operators who copied
  the old file need this edit too, or the collector will not start.

### Changed

- `Metrics freshness` now covers the container pipeline as well as the host
  pipeline, and reports the worst age of the two. It asked only for
  `system/load1`, which inputs.system keeps writing regardless, so it stayed OK
  for two days while every `docker_container_*` series was missing and the
  container dashboards were blank. `influxdb-freshness` takes an optional list
  of `<measurement>:<field>` series and defaults to `system:load1` plus
  `docker_container_mem:usage`.

- Grafana's container cap is 1g with `GOMEMLIMIT=600MiB`, was 512m with
  `GOMEMLIMIT=400MiB`. The old pair put the steady state at 443 MB of 512 MB
  and left `Container memory` on `ctr-grafana` permanently at WARNING with
  nothing wrong. `docs/deploy.md` now sizes `GOMEMLIMIT` to the working set
  and the cap to the headroom above it, rather than `GOMEMLIMIT` to 80% of
  the cap.

- The telegraf probe tests now run in the `sdlc ci` gate as a
  `pytest-in-image` check, instead of only during the image build.

## [0.4.0] - 2026-10-19

### Changed

- Trend alerts no longer page. Grafana routes every alert to a route muted
  around the clock, and Nagios shows the firing rules as a WARNING on the new
  `Trend alerts` service on `ctr-grafana`, which never notifies. Every trend
  page had been a no-action RCS text.

- Constitution is now a v1.18.0 manifest: it holds only what is specific to
  this repo; fleet and profile rules apply by reference.
- Constitution validation is pinned to the inherited release via
  `.github/workflows/constitution.yml`.
- Dependabot auto-merges GitHub Actions minor and patch updates.

### Added

- `/usr/local/bin/grafana-firing` prints the firing alert rules, one line per
  rule, using the Grafana container's own admin login, for the Nagios check.

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
