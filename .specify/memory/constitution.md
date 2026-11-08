# TIG Container Constitution

> **Version:** 1.2.0
> **Ratified:** 2026-09-30
> **Amended:** 2026-11-08
> **Status:** Active
> **Inherits:** [crunchtools/constitution](https://github.com/crunchtools/constitution) v1.31.0
> **Profile:** Container Image

This file holds what is specific to tig. The fleet rules and the Container
Image profile apply at the inherited version and are checked against this
repo's files by `constitution.yml`. They are not restated here.

## Image Purpose

One image, three roles: the Telegraf collector, the InfluxDB 2.x time-series
database and the Grafana dashboards and trend alerting. Each container runs
exactly one role, selected by the first argument to `/usr/local/bin/tig`. This
is the graphing and rate-of-change layer next to Nagios, which stays the
threshold alerting platform. Published to `quay.io/crunchtools/tig` and
`ghcr.io/crunchtools/tig`.

The roles are separate containers by design. The collector holds the Podman
socket and the host PID namespace; Grafana answers requests from the internet.
They MUST NOT share a container.

## Upstream Licenses

The three upstream programs keep their own licenses (Telegraf MIT, InfluxDB
MIT, Grafana AGPL-3.0); this repo's license covers the packaging, scripts and
provisioning.

## Consumer Interfaces

The interfaces consumers depend on are the measurement and field names
Telegraf writes, the datasource uid `influxdb`, the dashboard uids and the role
names accepted by `/usr/local/bin/tig`. Renaming any of them is MAJOR. A new
input, dashboard or alert rule is MINOR.

## Base Image and Packages

`registry.access.redhat.com/ubi10/ubi-minimal`. No systemd, no RHSM
registration: all three programs come from their upstream RPM repositories
(`rootfs/etc/yum.repos.d/`). There is no crunchtools parent image, so there is
no cascade rebuild.

- **Version pins:** upstream RPMs are pinned by minor-version glob in build
  `ARG`s (`INFLUXDB_VERSION`, `INFLUX_CLI_VERSION`, `GRAFANA_VERSION`). The
  weekly rebuild takes patch releases; a minor or major bump is a reviewed edit,
  because dashboards, alert rules and the rollup task consume those interfaces.
- **Deviation — `TELEGRAF_VERSION` is an exact pin, not a glob.** Every telegraf
  from 1.39.0 onward fails its entire container list against podman 5.8.2, which
  returns the literal string `<nil>` as a gatewayless network's `Gateway`, so
  `docker_container_*` collection stops completely while the collector still
  reports healthy. Gloval has five gatewayless networks. Measured there: 1.38.4
  collects all 61 series, 1.39.0 through 1.40.3 collect none. A glob reaches a
  broken release on the next weekly rebuild, which is exactly how this shipped
  (RT#1567). What it costs: patch releases are no longer picked up
  automatically, so a telegraf CVE needs a deliberate edit here.
  `tests/test-image.sh` asserts the exact version, and the Containerfile comment
  holds the procedure for lifting the pin — which requires evidence from
  gloval's own socket, because CI cannot reproduce the bug. Revisit when
  upstream fixes it or the five networks are given gateways.
- **Service accounts:** fixed IDs (influxdb 1501, grafana 1502), created before
  the RPMs are installed. Containers run without user namespaces, so these IDs
  own files on the host and must not collide with anything there.
- **Extras:** `python3` for the Telegraf exec inputs; `procps-ng` and `iproute`
  for debugging a collector in the host PID and network namespaces.
- **Script modes:** scripts are chmod'd with a glob, never a file list.

## Host Directories

Nothing role-specific is baked into the image. Each container has its own
`/srv/<container-name>/` on the host:

| Path | Mount | Contents |
|------|-------|----------|
| `config/etc/` | read-only into the container | the role's config files |
| `config/<name>.env` | `--env-file`, never mounted | secrets, mode 0600 |
| `config/<name>.service` | not mounted | copy of the installed unit |
| `data/` | read-write | InfluxDB engine, Grafana database |

`deploy/` in this repo is the source of truth for everything except secrets.
The repo carries only `*.env.example` and `*.conf.example` files; tokens,
passwords, the alert address and the list of database containers live under
`/srv` on the host.

## Nagios Checks and Trend Alerts

Container running and memory for each of the four containers, a TCP check on
each published port, an external HTTPS check on Grafana, and a metrics
freshness check that asks InfluxDB for the age of its newest point over the
Podman exec socket. Definitions are in `deploy/nagios/`.

Grafana's trend alert rules are not monitoring checks in the fleet sense: they
do not decide whether a service is up. They report time-to-exhaustion.

## Smoke Test Scope

`tests/test-image.sh` runs all three roles together: influxd bootstraps,
Telegraf writes with the shipped config, a Flux query reads the point back,
and Grafana starts with the shipped provisioning and reports its datasource
healthy.

## History

| Version | Date | Changes |
|---------|------|---------|
| 1.0.0 | 2026-09-30 | Initial constitution (RT #1461) |
| 1.1.0 | 2026-10-02 | Manifest under constitution v1.18.0: fleet and profile restatement removed, tig specifics kept |
| 1.2.0 | 2026-11-08 | `TELEGRAF_VERSION` carved out of the minor-glob rule as an exact pin, with the deviation and its cost recorded (RT #1567) |
