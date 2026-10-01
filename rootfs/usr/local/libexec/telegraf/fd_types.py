#!/usr/bin/python3
"""Telegraf exec input: open file descriptors by type, per process name.

Walks /proc/<pid>/fd for every process on the host and classifies each
descriptor as a regular file, pipe, TCP socket, UDP socket, Unix socket or
other. A process holding no descriptors, which is every kernel thread, is
skipped. Emits InfluxDB line protocol, one line per process name plus a host
total:

    fd_types,comm=httpd files=412i,pipes=38i,tcp=12i,udp=0i,unix=6i,other=9i,procs=11i

Needs the host PID namespace and CAP_SYS_PTRACE + CAP_DAC_READ_SEARCH to read
other users' /proc/<pid>/fd. A readlink only says "socket:[inode]", so the
socket type is resolved by looking that inode up in /proc/<pid>/net/{tcp,tcp6,
udp,udp6,unix}. Those tables are per network namespace, and they are cached by
namespace so 50 containers cost 50 reads, not one per process.
"""

import os
import re
import sys
from collections import defaultdict

PROC = "/proc"
KINDS = ("files", "pipes", "tcp", "udp", "unix", "other")
# Column holding the socket inode in each /proc/<pid>/net table.
NET_TABLES = (
    ("tcp", "tcp", 9),
    ("tcp6", "tcp", 9),
    ("udp", "udp", 9),
    ("udp6", "udp", 9),
    ("unix", "unix", 6),
)
# What a non-socket descriptor link starts with.
PREFIX_KINDS = (("/", "files"), ("pipe:", "pipes"))
SOCKET_RE = re.compile(r"^socket:\[(\d+)\]$")
# A process chooses its own name (prctl PR_SET_NAME) and may put anything in it,
# including a newline followed by a forged line-protocol record. Anything
# outside this set becomes "_" before the name is used as a tag value.
UNSAFE_TAG_RE = re.compile(r"[^A-Za-z0-9_.:/@+-]")


def socket_table(pid: str) -> dict[str, str]:
    """Map socket inode to kind for the network namespace `pid` lives in."""
    inodes: dict[str, str] = {}
    for name, kind, column in NET_TABLES:
        try:
            with open(f"{PROC}/{pid}/net/{name}", encoding="ascii", errors="replace") as table:
                next(table, None)
                for line in table:
                    fields = line.split()
                    if len(fields) > column:
                        inodes[fields[column]] = kind
        except OSError:
            continue
    return inodes


def classify(target: str, sockets: dict[str, str]) -> str:
    """Return the kind of one descriptor from its /proc/<pid>/fd link target.

    `sockets` maps socket inode to "tcp", "udp" or "unix" for the process's
    network namespace; a socket not in it (netlink, packet, raw) is "other".
    """
    match = SOCKET_RE.match(target)
    if match is not None:
        return sockets.get(match.group(1), "other")
    for prefix, kind in PREFIX_KINDS:
        if target.startswith(prefix):
            return kind
    return "other"


def main() -> int:
    """Write one fd_types record per process name and a host total; return 0."""
    counts: dict[str, dict[str, int]] = defaultdict(lambda: dict.fromkeys((*KINDS, "procs"), 0))
    tables: dict[str, dict[str, str]] = {}

    for pid in os.listdir(PROC):
        if not pid.isdigit():
            continue
        try:
            with open(f"{PROC}/{pid}/comm", encoding="utf-8", errors="replace") as handle:
                comm = handle.read().strip()
            fds = os.listdir(f"{PROC}/{pid}/fd")
            netns = os.readlink(f"{PROC}/{pid}/ns/net")
        except OSError:
            continue  # exited mid-walk
        # A kernel thread lists an empty fd directory rather than failing, and
        # kworkers rename themselves per job ("kworker/3:1-xfs-conv/sda4"), so
        # emitting them puts a new tag value in the bucket every few seconds.
        if not fds:
            continue

        if netns not in tables:
            tables[netns] = socket_table(pid)
        row = counts[comm or "unknown"]
        row["procs"] += 1
        for fd in fds:
            try:
                target = os.readlink(f"{PROC}/{pid}/fd/{fd}")
            except OSError:
                continue
            row[classify(target, tables[netns])] += 1

    total = dict.fromkeys((*KINDS, "procs"), 0)
    for comm, row in sorted(counts.items()):
        for key, value in row.items():
            total[key] += value
        tag = UNSAFE_TAG_RE.sub("_", comm)
        emit(f"fd_types,comm={tag}", row)
    emit("fd_types_total", total)
    return 0


def emit(series: str, row: dict[str, int]) -> None:
    """Write one line-protocol record: `series` (measurement and tags), integer fields."""
    fields = ",".join(f"{key}={value}i" for key, value in row.items())
    sys.stdout.write(f"{series} {fields}\n")


if __name__ == "__main__":
    sys.exit(main())
