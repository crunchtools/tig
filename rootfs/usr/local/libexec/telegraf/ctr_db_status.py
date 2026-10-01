#!/usr/bin/python3
"""Telegraf exec input: database counters from inside other containers.

Usage: ctr_db_status.py [--socket PATH] [CONFIG]

The databases on the deploy host live inside application containers and listen
only on their own loopback or Unix socket. Rather than publish ports and hand
out monitoring passwords, this runs the database's own client inside each
container over the Podman API socket, as the local superuser, and turns the
answer into InfluxDB line protocol (constitution XVI: credential-free, exec
socket):

    mysql_status,container=blog.example.com Threads_connected=3i,Questions=91234i
    postgres_status,container=app.example.com numbackends=4i,db_size_bytes=8112345i
    db_collector,container=app.example.com up=1i

CONFIG (default /etc/telegraf/db-containers.conf) has one
"<container-name> <mariadb|postgres> [db-user]" per line; "#" starts a comment.
db-user applies to postgres only and defaults to "postgres".

A container that is down, or answers garbage, is reported on stderr and gets
db_collector up=0. One sick database must not blank the others' graphs, so the
exit status is always 0.
"""

import argparse
import http.client
import json
import re
import socket
import struct
import sys
from urllib.parse import quote

DEFAULT_CONFIG = "/etc/telegraf/db-containers.conf"
DEFAULT_SOCKET = "/run/podman/podman.sock"
API_VERSION = "/v5.0.0"
TIMEOUT_SECONDS = 10
STDOUT_STREAM = 1
FRAME_HEADER_BYTES = 8
HTTP_ERROR = 400
REQUIRED_COLUMNS = ("container", "kind")
DEFAULT_DB_USER = "postgres"
UNSAFE_TAG_RE = re.compile(r"[^A-Za-z0-9_.:/@+-]")

# Global status counters worth graphing. Everything else SHOW GLOBAL STATUS
# returns is either a string or a number nobody has ever looked at.
MARIADB_FIELDS = frozenset(
    """
    Threads_connected Threads_running Max_used_connections Aborted_clients Aborted_connects
    Connections Questions Slow_queries Bytes_received Bytes_sent
    Com_select Com_insert Com_update Com_delete
    Innodb_buffer_pool_pages_free Innodb_buffer_pool_pages_total Innodb_buffer_pool_reads
    Innodb_buffer_pool_read_requests Innodb_row_lock_waits
    Handler_read_first Handler_read_key Handler_read_next Handler_read_rnd Handler_read_rnd_next
    Created_tmp_disk_tables Created_tmp_tables Open_tables Opened_tables Table_locks_waited
    """.split()
)

POSTGRES_COUNTERS = (
    "numbackends xact_commit xact_rollback blks_read blks_hit tup_returned tup_fetched "
    "tup_inserted tup_updated tup_deleted deadlocks temp_files"
).split()
POSTGRES_SQL = " UNION ALL ".join(
    [f"SELECT '{name}', sum({name}) FROM pg_stat_database" for name in POSTGRES_COUNTERS]
    + ["SELECT 'db_size_bytes', sum(pg_database_size(datname)) FROM pg_database"]
)
POSTGRES_FIELDS = frozenset((*POSTGRES_COUNTERS, "db_size_bytes"))


class ExecError(Exception):
    """The Podman API refused the exec, or the command inside exited non-zero."""


class UnixHTTPConnection(http.client.HTTPConnection):
    """An HTTP connection to the Podman API over its Unix socket."""

    def __init__(self, socket_path: str) -> None:
        super().__init__("localhost", timeout=TIMEOUT_SECONDS)
        self._socket_path = socket_path

    def connect(self) -> None:
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(TIMEOUT_SECONDS)
        self.sock.connect(self._socket_path)


def api_request(socket_path: str, method: str, path: str, body: dict | None = None) -> bytes:
    """Send one request to the Podman API and return the raw response body."""
    connection = UnixHTTPConnection(socket_path)
    try:
        payload = None if body is None else json.dumps(body)
        headers = {} if body is None else {"Content-Type": "application/json"}
        connection.request(method, API_VERSION + path, body=payload, headers=headers)
        response = connection.getresponse()
        response_body = response.read()
    finally:
        connection.close()
    if response.status >= HTTP_ERROR:
        raise ExecError(f"{method} {path}: HTTP {response.status} {response_body[:200]!r}")
    return response_body


def demux(stream: bytes) -> str:
    """Return the stdout payload of a Docker-style multiplexed exec stream.

    Each frame is an 8-byte header (stream id, three zero bytes, big-endian
    payload length) followed by the payload. The header has to be parsed, not
    filtered out: its length bytes are often printable ASCII or a newline, and
    a filter would leave them in the middle of the command's output.
    """
    stdout = bytearray()
    position = 0
    while position + FRAME_HEADER_BYTES <= len(stream):
        stream_id = stream[position]
        (length,) = struct.unpack(">I", stream[position + 4 : position + FRAME_HEADER_BYTES])
        position += FRAME_HEADER_BYTES
        if stream_id == STDOUT_STREAM:
            stdout += stream[position : position + length]
        position += length
    return stdout.decode("utf-8", errors="replace")


def container_exec(socket_path: str, container: str, argv: list[str]) -> str:
    """Run argv inside container and return its stdout; raise ExecError on failure."""
    create = {"Cmd": argv, "AttachStdout": True, "AttachStderr": True}
    create_path = f"/containers/{quote(container, safe='')}/exec"
    exec_id = json.loads(api_request(socket_path, "POST", create_path, create))["Id"]
    stream = api_request(socket_path, "POST", f"/exec/{exec_id}/start", {"Detach": False})
    exit_code = json.loads(api_request(socket_path, "GET", f"/exec/{exec_id}/json")).get("ExitCode")
    if exit_code != 0:
        raise ExecError(f"{argv[0]} in {container} exited {exit_code}")
    return demux(stream)


def parse_pairs(text: str, separator: str, wanted: frozenset[str]) -> dict[str, int]:
    """Parse "name<separator>value" lines, keeping wanted names with integer values."""
    fields: dict[str, int] = {}
    for line in text.splitlines():
        name, found, value = line.strip().partition(separator)
        if found and name in wanted and value.isascii() and value.isdigit():
            fields[name] = int(value)
    return fields


def line_protocol(measurement: str, container: str, fields: dict[str, int]) -> str:
    """Format one line-protocol record, or an empty string if there are no fields."""
    if not fields:
        return ""
    tag = UNSAFE_TAG_RE.sub("_", container)
    body = ",".join(f"{name}={value}i" for name, value in fields.items())
    return f"{measurement},container={tag} {body}\n"


def collect(socket_path: str, container: str, kind: str, db_user: str) -> str:
    """Query one container and return its line-protocol record."""
    if kind == "mariadb":
        output = container_exec(socket_path, container, ["mariadb", "-N", "-B", "-e", "SHOW GLOBAL STATUS"])
        return line_protocol("mysql_status", container, parse_pairs(output, "\t", MARIADB_FIELDS))
    if kind == "postgres":
        argv = ["psql", "-U", db_user, "-d", "postgres", "-At", "-F", "|", "-c", POSTGRES_SQL]
        output = container_exec(socket_path, container, argv)
        return line_protocol("postgres_status", container, parse_pairs(output, "|", POSTGRES_FIELDS))
    raise ExecError(f"unknown kind '{kind}' for {container}")


def read_config(path: str) -> list[tuple[str, str, str]]:
    """Return (container, kind, db-user) for each entry; a missing file is empty."""
    entries = []
    try:
        with open(path, encoding="utf-8") as handle:
            for raw in handle:
                words = raw.split("#", 1)[0].split()
                if len(words) < len(REQUIRED_COLUMNS):
                    continue
                container, kind, *rest = words
                entries.append((container, kind, rest[0] if rest else DEFAULT_DB_USER))
    except FileNotFoundError:
        return []
    return entries


def main() -> int:
    """Print one record per configured container; always exit 0."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("config", nargs="?", default=DEFAULT_CONFIG)
    parser.add_argument("--socket", default=DEFAULT_SOCKET, help="Podman API socket path")
    args = parser.parse_args()

    for container, kind, db_user in read_config(args.config):
        reachable = 1
        try:
            record = collect(args.socket, container, kind, db_user)
        except (ExecError, OSError, ValueError, KeyError) as error:
            # The failure becomes data: db_collector.up goes to 0 for this
            # container, so a database that stops answering shows on a graph
            # instead of as a silent gap.
            print(f"ctr_db_status: {container}: {error}", file=sys.stderr)
            record = ""
            reachable = 0
        sys.stdout.write(record + line_protocol("db_collector", container, {"up": reachable}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
