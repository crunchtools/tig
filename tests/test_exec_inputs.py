#!/usr/bin/python3
"""Unit tests for the Telegraf exec inputs.

Run inside the image, where the inputs live at their installed path:

    python3 tests/test_exec_inputs.py

tests/test-image.sh does this in CI. Standard library only; the image carries
no test framework.
"""

import importlib
import struct
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, "/usr/local/libexec/telegraf")

ctr_db_status = importlib.import_module("ctr_db_status")
fd_types = importlib.import_module("fd_types")


def frame(stream_id: int, payload: bytes) -> bytes:
    """Build one frame of a Docker-style multiplexed exec stream."""
    return bytes([stream_id, 0, 0, 0]) + struct.pack(">I", len(payload)) + payload


class TagSanitisation(unittest.TestCase):
    """A process picks its own name; it must not be able to forge a record."""

    def test_hostile_names_collapse_to_one_safe_tag(self) -> None:
        cases = {
            "evil\nfd_types,comm=x files=9i d=e f": "evil_fd_types_comm_x_files_9i_d_e_f",
            "a\n\nb\rc\td": "a__b_c_d",
            '$(reboot);`id`|&\\"': "__reboot___id_____",
            "café x": "caf__x",
        }
        for raw, want in cases.items():
            self.assertEqual(fd_types.UNSAFE_TAG_RE.sub("_", raw), want)

    def test_ordinary_names_pass_through(self) -> None:
        name = "kworker/0:1H-kblockd"
        self.assertEqual(fd_types.UNSAFE_TAG_RE.sub("_", name), name)


class DescriptorClassification(unittest.TestCase):
    def test_every_kind(self) -> None:
        sockets = {"11": "tcp", "12": "udp", "13": "unix"}
        cases = {
            "/var/log/messages": "files",
            "pipe:[4242]": "pipes",
            "socket:[11]": "tcp",
            "socket:[12]": "udp",
            "socket:[13]": "unix",
            "socket:[99]": "other",
            "anon_inode:[eventpoll]": "other",
        }
        for target, want in cases.items():
            self.assertEqual(fd_types.classify(target, sockets), want)

    def test_socket_table_reads_the_inode_column_of_each_table(self) -> None:
        # Header row, then one socket; the inode is the tenth column.
        tcp = (
            "sl local_address rem_address st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode\n"
            "0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000 0 0 4001 1 x\n"
        )
        udp = (
            "sl local_address rem_address st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode\n"
            "500: 00000000:0044 00000000:0000 07 00000000:00000000 00:00000000 00000000 0 0 5002 2 x\n"
        )
        unix = (
            "Num       RefCount Protocol Flags    Type St Inode Path\n"
            "0000000000000000: 00000002 00000000 00010000 0001 01 6003 /run/x.sock\n"
        )
        with tempfile.TemporaryDirectory() as root:
            net = Path(root, "42", "net")
            net.mkdir(parents=True)
            (net / "tcp").write_text(tcp)
            (net / "udp").write_text(udp)
            (net / "unix").write_text(unix)
            original = fd_types.PROC
            fd_types.PROC = root
            try:
                table = fd_types.socket_table("42")
            finally:
                fd_types.PROC = original
        self.assertEqual(table, {"4001": "tcp", "5002": "udp", "6003": "unix"})

    def test_missing_proc_entry_gives_an_empty_table(self) -> None:
        self.assertEqual(fd_types.socket_table("0"), {})


class ExecStreamDemux(unittest.TestCase):
    def test_keeps_stdout_and_drops_stderr(self) -> None:
        stream = frame(1, b"Questions\t10\n") + frame(2, b"warning: noise\n") + frame(1, b"Slow_queries\t0\n")
        self.assertEqual(ctr_db_status.demux(stream), "Questions\t10\nSlow_queries\t0\n")

    def test_printable_length_bytes_do_not_leak_into_output(self) -> None:
        # 0x0A31 bytes of payload: the header's length field is "\n1", which a
        # printable-character filter would leave in front of the first line.
        payload = b"x" * 0x0A31
        self.assertEqual(ctr_db_status.demux(frame(1, payload)), payload.decode())

    def test_line_split_across_frames_is_rejoined(self) -> None:
        stream = frame(1, b"Threads_conn") + frame(1, b"ected\t7\n")
        self.assertEqual(ctr_db_status.demux(stream), "Threads_connected\t7\n")

    def test_empty_and_truncated_streams(self) -> None:
        self.assertEqual(ctr_db_status.demux(b""), "")
        self.assertEqual(ctr_db_status.demux(b"\x01\x00\x00"), "")


class StatusParsing(unittest.TestCase):
    def test_mariadb_keeps_allow_listed_integers_only(self) -> None:
        text = (
            "Threads_connected\t3\nQuestions\t91234\nSsl_cipher\t\nUptime\t55\nSlow_queries\tNULL\ngarbage\n"
        )
        fields = ctr_db_status.parse_pairs(text, "\t", ctr_db_status.MARIADB_FIELDS)
        self.assertEqual(fields, {"Threads_connected": 3, "Questions": 91234})

    def test_postgres_pairs(self) -> None:
        text = "numbackends|4\nxact_commit|1200\ndb_size_bytes|8112345\nnot_a_counter|1\ndeadlocks|\n"
        fields = ctr_db_status.parse_pairs(text, "|", ctr_db_status.POSTGRES_FIELDS)
        self.assertEqual(fields, {"numbackends": 4, "xact_commit": 1200, "db_size_bytes": 8112345})

    def test_line_protocol_record(self) -> None:
        fields = {"Questions": 9, "Slow_queries": 0}
        record = ctr_db_status.line_protocol("mysql_status", "blog.example.com", fields)
        self.assertEqual(record, "mysql_status,container=blog.example.com Questions=9i,Slow_queries=0i\n")

    def test_no_fields_means_no_record(self) -> None:
        self.assertEqual(ctr_db_status.line_protocol("mysql_status", "blog.example.com", {}), "")

    def test_container_name_is_sanitised(self) -> None:
        record = ctr_db_status.line_protocol("mysql_status", "a b,c=d\ne", {"Questions": 1})
        self.assertEqual(record, "mysql_status,container=a_b_c_d_e Questions=1i\n")


class ConfigReading(unittest.TestCase):
    def test_entries_comments_and_default_user(self) -> None:
        with tempfile.NamedTemporaryFile("w", suffix=".conf") as handle:
            handle.write("# comment\n\nblog.example.com mariadb\n")
            handle.write("app.example.com postgres appuser  # trailing\nbroken\n")
            handle.flush()
            entries = ctr_db_status.read_config(handle.name)
        self.assertEqual(
            entries,
            [("blog.example.com", "mariadb", "postgres"), ("app.example.com", "postgres", "appuser")],
        )

    def test_missing_config_is_empty(self) -> None:
        self.assertEqual(ctr_db_status.read_config("/nonexistent/db-containers.conf"), [])

    def test_unreachable_socket_raises_oserror(self) -> None:
        with self.assertRaises(OSError):
            ctr_db_status.container_exec("/nonexistent/podman.sock", "x", ["true"])


if __name__ == "__main__":
    unittest.main(verbosity=1)
