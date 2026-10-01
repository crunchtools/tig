#!/bin/bash
# Telegraf exec input: database counters from inside other containers.
#
# Usage: ctr_db_status.sh [/etc/telegraf/db-containers.conf]
#
# The databases on the deploy host live inside application containers and
# listen only on their own loopback or Unix socket. Rather than publish ports
# and hand out monitoring passwords, this runs the database's own client inside
# each container over the Podman API socket, as the local superuser, and turns
# the answer into line protocol (constitution XVI: credential-free, exec socket).
#
# Config: one "<container-name> <mariadb|postgres> [db-user]" per line; # starts a
# comment. db-user applies to postgres only and defaults to "postgres".
# A container that is down or answers garbage is skipped, not fatal — one sick
# database must not blank the others' graphs.

set -u

CONF="${1:-/etc/telegraf/db-containers.conf}"
EXEC="$(dirname "$0")/podman_exec.sh"

# Global status counters worth graphing. Everything else SHOW GLOBAL STATUS
# returns is either a string or a number nobody has ever looked at.
MARIADB_FIELDS="Threads_connected Threads_running Max_used_connections Aborted_clients Aborted_connects \
Connections Questions Slow_queries Bytes_received Bytes_sent \
Com_select Com_insert Com_update Com_delete \
Innodb_buffer_pool_pages_free Innodb_buffer_pool_pages_total Innodb_buffer_pool_reads \
Innodb_buffer_pool_read_requests Innodb_row_lock_waits \
Handler_read_first Handler_read_key Handler_read_next Handler_read_rnd Handler_read_rnd_next \
Created_tmp_disk_tables Created_tmp_tables Open_tables Opened_tables Table_locks_waited"

POSTGRES_SQL="SELECT 'numbackends', sum(numbackends) FROM pg_stat_database
UNION ALL SELECT 'xact_commit', sum(xact_commit) FROM pg_stat_database
UNION ALL SELECT 'xact_rollback', sum(xact_rollback) FROM pg_stat_database
UNION ALL SELECT 'blks_read', sum(blks_read) FROM pg_stat_database
UNION ALL SELECT 'blks_hit', sum(blks_hit) FROM pg_stat_database
UNION ALL SELECT 'tup_returned', sum(tup_returned) FROM pg_stat_database
UNION ALL SELECT 'tup_fetched', sum(tup_fetched) FROM pg_stat_database
UNION ALL SELECT 'tup_inserted', sum(tup_inserted) FROM pg_stat_database
UNION ALL SELECT 'tup_updated', sum(tup_updated) FROM pg_stat_database
UNION ALL SELECT 'tup_deleted', sum(tup_deleted) FROM pg_stat_database
UNION ALL SELECT 'deadlocks', sum(deadlocks) FROM pg_stat_database
UNION ALL SELECT 'temp_files', sum(temp_files) FROM pg_stat_database
UNION ALL SELECT 'db_size_bytes', sum(pg_database_size(datname)) FROM pg_database"

# Reads "name<sep>value" lines on stdin and prints one line-protocol record.
# Only names in the allow-list and integer values survive.
to_line_protocol() {
    local measurement="$1" container="$2" separator="$3" wanted="$4"
    awk -F"$separator" -v m="$measurement" -v c="$container" -v wanted="$wanted" '
        BEGIN { n = split(wanted, w, " "); for (i = 1; i <= n; i++) keep[w[i]] = 1 }
        (wanted == "" || $1 in keep) && $2 ~ /^[0-9]+$/ {
            fields = fields (fields == "" ? "" : ",") $1 "=" $2 "i"
        }
        END { if (fields != "") printf "%s,container=%s %s\n", m, c, fields }
    '
}

[ -r "$CONF" ] || exit 0

while read -r container kind dbuser _; do
    case "$container" in ""|\#*) continue ;; esac
    case "$kind" in
        mariadb)
            "$EXEC" "$container" mariadb -N -B -e "SHOW GLOBAL STATUS" 2>/dev/null \
                | to_line_protocol mysql_status "$container" "\t" "$MARIADB_FIELDS"
            ;;
        postgres)
            "$EXEC" "$container" psql -U "${dbuser:-postgres}" -d postgres -At -F "|" -c "$POSTGRES_SQL" 2>/dev/null \
                | to_line_protocol postgres_status "$container" "|" ""
            ;;
        *)
            echo "ctr_db_status: unknown kind '$kind' for $container" >&2
            ;;
    esac
done < "$CONF"

exit 0
