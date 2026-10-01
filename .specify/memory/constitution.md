# TIG Container Constitution

> **Version:** 1.0.0
> **Ratified:** 2026-09-30
> **Status:** Active
> **Inherits:** [crunchtools/constitution](https://github.com/crunchtools/constitution) v1.17.0
> **Profile:** Container Image

## License

AGPL-3.0-or-later, per universal constitution I. The three upstream programs
keep their own licenses (Telegraf MIT, InfluxDB MIT, Grafana AGPL-3.0); this
repo's license covers the packaging, scripts and provisioning.

## Semantic Versioning

Semantic Versioning 2.0.0, per universal constitution II, recorded in
`CHANGELOG.md`. The interfaces consumers depend on are the measurement and
field names Telegraf writes, the datasource uid `influxdb`, the dashboard uids
and the role names accepted by `/usr/local/bin/tig`. Renaming any of them is
MAJOR. A new input, dashboard or alert rule is MINOR.

## Image Purpose

One image, three roles: the Telegraf collector, the InfluxDB 2.x time-series
database and the Grafana dashboards and trend alerting. Each container runs
exactly one role, selected by the first argument to the entrypoint. This is the
graphing and rate-of-change layer next to Nagios, which stays the threshold
alerting platform.

The roles are separate containers by design, not for tidiness. The collector
holds the Podman socket and the host PID namespace; Grafana answers requests
from the internet. They MUST NOT share a container.

## Base Image

`registry.access.redhat.com/ubi10/ubi-minimal`. No systemd, no RHSM
registration: all three programs come from their upstream RPM repositories.
There is no crunchtools parent image, so there is no cascade rebuild.

## Container Registry

Dual-pushed to `quay.io/crunchtools/tig` (primary) and `ghcr.io/crunchtools/tig`
as two jobs with gha layer caching, per universal constitution III.

## Containerfile Conventions

- `Containerfile`, never `Dockerfile`; `microdnf clean all` after installs.
- Required LABELs: `maintainer`, `description`, and the OCI `source`,
  `description` and `licenses` labels.
- Upstream RPM versions are pinned by minor-version glob in build `ARG`s. The
  weekly rebuild takes patch releases; a minor or major bump is a reviewed
  edit, because dashboards, alert rules and the rollup task consume those
  interfaces.
- Service accounts have fixed IDs (influxdb 1501, grafana 1502), created before
  the RPMs are installed. Containers run without user namespaces, so these IDs
  own files on the host and must not collide with anything there.
- `rootfs/` mirrors the image layout. Scripts are chmod'd with a glob.

## Runtime Configuration

Per universal constitution XIV, nothing role-specific is baked into the image.
Each container has its own `/srv/<container-name>/` on the host:

| Path | Mount | Contents |
|------|-------|----------|
| `config/etc/` | read-only into the container | the role's config files |
| `config/<name>.env` | `--env-file`, never mounted | secrets, mode 0600 |
| `config/<name>.service` | not mounted | copy of the installed unit |
| `data/` | read-write | InfluxDB engine, Grafana database |

`deploy/` in this repo is the source of truth for everything except secrets.

## Secrets and Identifiable Data

This repository is PUBLIC. Per universal constitution XVII it carries only
`*.env.example` and `*.conf.example` files. Tokens, passwords, the alert
address and the list of database containers live under `/srv` on the host.

## Monitoring

Per universal constitution XVI, all checks are Nagios NRPE plugins:
container running and memory for each of the four containers, a TCP check on
each published port, an external HTTPS check on Grafana, and a metrics
freshness check that asks InfluxDB for the age of its newest point over the
Podman exec socket. Definitions are in `deploy/nagios/`.

Grafana's trend alert rules are not monitoring checks in the XVI sense: they
do not decide whether a service is up. They report time-to-exhaustion.

## Testing

CI on every pull request runs a **build test** (the image builds from
`Containerfile`) and then `tests/test-image.sh`, a **smoke test** that runs all
three roles together: influxd bootstraps, Telegraf writes with the shipped
config, a Flux query reads the point back, and Grafana starts with the shipped
provisioning and reports its datasource healthy. A **security scan** (Trivy)
runs on the published image.

## Quality Gates

Gourmand (blocking) and Gatehouse (advisory) run on every pull request, per
universal constitution XII, from their container images via the reusable
workflows in `crunchtools/gatehouse`.
