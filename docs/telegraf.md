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
| `mysql_status`, `postgres_status` | `ctr_db_status.sh` | tagged `container`; counters |

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
by process name to keep the series count bounded.

## Database counters

Databases on the host live inside application containers and listen only on
their own loopback. `ctr_db_status.sh` runs the database's own client inside
each one over the Podman exec socket, as the local superuser, so no monitoring
password exists anywhere. Containers are listed in
`/srv/telegraf.crunchtools.com/config/etc/db-containers.conf`:

```
<container-name> <mariadb|postgres> [db-user]
```
