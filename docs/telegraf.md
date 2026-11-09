# Collect: Telegraf

Two Telegraf containers. `telegraf-host` gathers metrics from the host it runs
on, every 30 seconds; config `deploy/telegraf-host/telegraf.conf`.
`telegraf-receiver` receives what services send it; see
[Trentina call traces](#trentina-call-traces).

## What it writes

| Measurement | Source | Notes |
|-------------|--------|-------|
| `cpu` | `inputs.cpu` | `cpu-total` only; user, system, iowait, steal |
| `mem`, `swap`, `system`, `processes` | built-in | |
| `disk` | `inputs.disk` | host filesystems via `/hostfs` |
| `diskio` | `inputs.diskio` | whole disks; counters |
| `net` | `inputs.net` | physical, bridge and WireGuard interfaces; counters |
| `docker`, `docker_container_cpu`, `docker_container_mem`, `docker_container_net`, `docker_container_blkio` | `inputs.docker` against the Podman socket | tagged `container_name` |
| `fd_types`, `fd_types_total` | `fd_types.py` | files, pipes, tcp, udp, unix, other; tagged `comm` |
| `mysql_status`, `postgres_status` | `ctr_db_status.py` | tagged `container`; counters |
| `db_collector` | `ctr_db_status.py` | `up` is 0 when a container's database did not answer |

## Host access

The collector needs to see the host, so its container has the host PID and
network namespaces, the Podman socket, and `/` mounted read-only at `/hostfs`.
It keeps two capabilities (`SYS_PTRACE`, `DAC_READ_SEARCH`) to read other
users' `/proc/<pid>/fd`, drops the rest, and has a read-only root filesystem.

The Podman socket is root on the host. Never add a listening service to this
container.

## File descriptors by type

`fd_types.py` walks `/proc/<pid>/fd` for every process. A descriptor link only
says `socket:[inode]`, so the script resolves TCP, UDP and Unix by looking the
inode up in `/proc/<pid>/net/*`, cached per network namespace. Output is summed
by process name to keep the series count bounded. A process holding no
descriptors is skipped: that is every kernel thread, and kworkers rename
themselves per job, which would otherwise add a tag value every few seconds.
`fd_types_total.procs` therefore counts processes that hold descriptors.

## Database counters

Databases on the host live inside application containers and listen only on
their own loopback. `ctr_db_status.py` runs the database's own client inside
each one over the Podman exec socket, as the local superuser, so no monitoring
password exists anywhere. It speaks to the socket directly and decodes the
multiplexed exec stream frame by frame. Containers are listed in
`/srv/telegraf-host.crunchtools.com/config/etc/db-containers.conf`:

```
<container-name> <mariadb|postgres> [db-user]
```

## Trentina call traces

`telegraf-receiver.crunchtools.com` is the second Telegraf, with one input: an
OTLP (OpenTelemetry Protocol) over HTTP receiver (`http_listener_v2`, port 4318, `/v1/traces`, basic auth)
for the spans Trentina exports (`TRENTINA_OTLP_ENDPOINT`). Telegraf's own
OTLP input speaks gRPC only, so the spans come as OTLP/JSON and an xpath
parser maps each one to a `trentina_calls` point:

- tags: `profile`, `backend`, `tool`, `outcome`, `destination_kind`, `layer`,
  `risk`, `l3_verdict`
- fields: `duration_ms`, `bytes_arrived`, `bytes_delivered`, `success`,
  `trace_id`

It runs apart from `telegraf-host` because it answers requests from other
containers: no host network, PID namespace, socket, mounts or capabilities.
The points keep the span's nanosecond timestamp, so two calls with the same
tags never overwrite each other. The Trentina dashboard reads them.

The dashboard (`deploy/grafana/dashboards/trentina.json`) is a copy of
`contrib/grafana/trentina-dashboard.json` in crunchtools/trentina: edit it
there and copy it here. How to read every panel is in trentina's
`docs/grafana-dashboard.md`.
