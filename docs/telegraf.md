# Collect: Telegraf

One collector container per host, on a 30-second interval. Config is
`deploy/telegraf/telegraf.conf`.

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
`/srv/telegraf.crunchtools.com/config/etc/db-containers.conf`:

```
<container-name> <mariadb|postgres> [db-user]
```

## OpenRouter spend

`openrouter_usage.py` reads OpenRouter with a management key
(`OPENROUTER_MANAGEMENT_KEY` in `telegraf.env`) every 15 minutes:

- `openrouter_usage,model,key`: cost, requests and tokens per UTC day, from
  `POST /api/v1/analytics/query`, the source behind OpenRouter's activity
  page. The last three days are read on every run and stamped at UTC
  midnight, so each day's figure is replaced as it settles instead of being
  counted twice. Every agent has its own key, so `key` is the agent.
- `openrouter_key,key`: the running `usage_daily`, `usage_weekly`,
  `usage_monthly` and `limit_remaining` per key, from `/keys`.
- `openrouter_credits`: `total_credits`, `total_usage` and `balance`.
- `openrouter_collector up`: 0 when the key is missing or any read failed.
  The failure kind goes to stderr; the key never does.

A management key can create and delete keys. It lives only in `telegraf.env`
(0600) and is sent only in the Authorization header.

## Trentina call traces

`telegraf-otlp.crunchtools.com` is a second Telegraf with one input: an
OTLP/HTTP receiver (`http_listener_v2`, port 4318, `/v1/traces`, basic auth)
for the spans Trentina exports (`TRENTINA_OTLP_ENDPOINT`). Telegraf's own
OTLP input speaks gRPC only, so the spans come as OTLP/JSON and an xpath
parser maps each one to a `trentina_calls` point:

- tags: `profile`, `backend`, `tool`, `outcome`, `destination_kind`, `layer`,
  `risk`, `l3_verdict`
- fields: `duration_ms`, `bytes_arrived`, `bytes_delivered`, `success`,
  `trace_id`

It runs apart from the host collector because it answers requests from other
containers: no host network, PID namespace, socket, mounts or capabilities.
The points keep the span's nanosecond timestamp, so two calls with the same
tags never overwrite each other. The Trentina dashboard reads both.
