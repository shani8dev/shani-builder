#!/bin/bash
# build-metrics.sh — Track build metrics in a SQLite database.
#
# DB location: ~/.local/share/shani-builder/metrics.db
# Schema: (pkgbase TEXT, status TEXT, start_time REAL, end_time REAL,
#          error TEXT, commit_sha TEXT)
#
# Event names: builds.success, builds.failed, builds.timeout, builds.alreadyBuilt
#
# Usage:
#   ./pkg/build-metrics.sh record <pkgbase> <status> <start_time> <end_time> [error] [commit_sha]
#   ./pkg/build-metrics.sh query-failures          — SELECT pkgbase, COUNT(*) WHERE status='failed' GROUP BY pkgbase
#   ./pkg/build-metrics.sh summary                 — counts by status
#   ./pkg/build-metrics.sh export-prometheus       — Prometheus text format
#   ./pkg/build-metrics.sh init                    — create DB + schema (auto-run on first use)

set -euo pipefail

DB_DIR="${HOME}/.local/share/shani-builder"
DB_PATH="${DB_DIR}/metrics.db"

# ---------------------------------------------------------------------------
# Ensure DB directory exists
# ---------------------------------------------------------------------------
mkdir -p "${DB_DIR}"

# ---------------------------------------------------------------------------
# Core DB operations via Python (sqlite3 CLI not guaranteed on all systems)
# ---------------------------------------------------------------------------
_db_cmd() {
    python3 - "${DB_PATH}" "$@" <<'PYEOF'
import sqlite3
import sys
import os

db_path = sys.argv[1]
cmd = sys.argv[2]
args = sys.argv[3:]

os.makedirs(os.path.dirname(db_path), exist_ok=True)
conn = sqlite3.connect(db_path)
cur = conn.cursor()

if cmd == "init":
    cur.execute("""
        CREATE TABLE IF NOT EXISTS builds (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            pkgbase TEXT NOT NULL,
            status TEXT NOT NULL,
            start_time REAL,
            end_time REAL,
            error TEXT,
            commit_sha TEXT
        )
    """)
    cur.execute("""
        CREATE INDEX IF NOT EXISTS idx_builds_pkgbase ON builds(pkgbase)
    """)
    cur.execute("""
        CREATE INDEX IF NOT EXISTS idx_builds_status ON builds(status)
    """)
    conn.commit()

elif cmd == "record":
    pkgbase, status, start_time, end_time = args[0], args[1], float(args[2]), float(args[3])
    error = args[4] if len(args) > 4 else None
    commit_sha = args[5] if len(args) > 5 else None
    cur.execute(
        "INSERT INTO builds (pkgbase, status, start_time, end_time, error, commit_sha) VALUES (?,?,?,?,?,?)",
        (pkgbase, status, start_time, end_time, error, commit_sha),
    )
    conn.commit()

elif cmd == "query-failures":
    cur.execute(
        "SELECT pkgbase, COUNT(*) FROM builds WHERE status='failed' GROUP BY pkgbase ORDER BY COUNT(*) DESC"
    )
    rows = cur.fetchall()
    for pkgbase, count in rows:
        print(f"{pkgbase}\t{count}")

elif cmd == "summary":
    cur.execute("SELECT status, COUNT(*) FROM builds GROUP BY status ORDER BY status")
    rows = cur.fetchall()
    for status, count in rows:
        print(f"{status}\t{count}")

elif cmd == "export-prometheus":
    # Build metrics overview
    cur.execute("SELECT COUNT(*), MIN(start_time), MAX(end_time) FROM builds")
    total, min_t, max_t = cur.fetchone()
    print(f"# HELP shani_builds_total Total number of builds tracked")
    print(f"# TYPE shani_builds_total counter")
    print(f'shani_builds_total {total or 0}')

    if min_t is not None and max_t is not None:
        print(f"# HELP shani_builds_time_range_seconds Time range of tracked builds")
        print(f"# TYPE shani_builds_time_range_seconds gauge")
        print(f"shani_builds_time_range_seconds {max_t - min_t}")

    # Per-status counts
    cur.execute("SELECT status, COUNT(*) FROM builds GROUP BY status")
    for status, count in cur.fetchall():
        label = status.replace("-", "_").replace(" ", "_")
        print(f"# HELP shani_builds_status_{label} Builds with status {status}")
        print(f"# TYPE shani_builds_status_{label} counter")
        print(f'shani_builds_status_{label} {{status="{status}"}} {count}')

    # Per-package failure counts
    cur.execute("SELECT pkgbase, COUNT(*) FROM builds WHERE status='failed' GROUP BY pkgbase ORDER BY COUNT(*) DESC LIMIT 20")
    for pkgbase, count in cur.fetchall():
        label = pkgbase.replace("-", "_").replace(" ", "_").replace(".", "_")
        print(f"# HELP shani_builds_failures_pkg_{label} Failure count for {pkgbase}")
        print(f"# TYPE shani_builds_failures_pkg_{label} counter")
        print(f'shani_builds_failures_pkg_{label} {{pkgbase="{pkgbase}"}} {count}')

    # Per-package build counts
    cur.execute("SELECT pkgbase, COUNT(*) FROM builds GROUP BY pkgbase ORDER BY COUNT(*) DESC LIMIT 20")
    for pkgbase, count in cur.fetchall():
        label = pkgbase.replace("-", "_").replace(" ", "_").replace(".", "_")
        print(f"# HELP shani_builds_total_pkg_{label} Total build count for {pkgbase}")
        print(f"# TYPE shani_builds_total_pkg_{label} counter")
        print(f'shani_builds_total_pkg_{label} {{pkgbase="{pkgbase}"}} {count}')

    # Per-build duration (last 100 builds)
    cur.execute("SELECT pkgbase, status, (end_time - start_time) AS duration FROM builds WHERE end_time IS NOT NULL ORDER BY id DESC LIMIT 100")
    for pkgbase, status, duration in cur.fetchall():
        label_pkg = pkgbase.replace("-", "_").replace(" ", "_").replace(".", "_")
        label_status = status.replace("-", "_").replace(" ", "_")
        print(f"# HELP shani_build_duration_seconds Duration of a single build")
        print(f"# TYPE shani_build_duration_seconds gauge")
        print(f'shani_build_duration_seconds {{pkgbase="{pkgbase}",status="{status}"}} {duration:.3f}')

elif cmd == "count":
    cur.execute("SELECT COUNT(*) FROM builds")
    print(cur.fetchone()[0])

elif cmd == "last-commit":
    cur.execute("SELECT commit_sha FROM builds WHERE commit_sha IS NOT NULL ORDER BY id DESC LIMIT 1")
    row = cur.fetchone()
    print(row[0] if row else "")

conn.close()
PYEOF
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $0 <command> [args...]

Commands:
  record <pkgbase> <status> <start_time> <end_time> [error] [commit_sha]
      Record a build metric entry.
      status: success | failed | timeout | alreadyBuilt
  query-failures
      List packages with failed builds: pkgbase<TAB>count
  summary
      Show build counts grouped by status
  export-prometheus
      Export metrics in Prometheus text format
  init
      Create the database and schema
  count
      Total number of recorded builds
  last-commit
      Last commit SHA recorded
EOF
}

cmd="${1:-}"
shift 2>/dev/null || true

case "$cmd" in
    record)
        if [[ $# -lt 4 ]]; then
            echo "Usage: $0 record <pkgbase> <status> <start_time> <end_time> [error] [commit_sha]" >&2
            exit 1
        fi
        _db_cmd init
        _db_cmd record "$@"
        ;;
    query-failures)
        _db_cmd init
        _db_cmd query-failures
        ;;
    summary)
        _db_cmd init
        _db_cmd summary
        ;;
    export-prometheus)
        _db_cmd init
        _db_cmd export-prometheus
        ;;
    init)
        _db_cmd init
        ;;
    count)
        _db_cmd init
        _db_cmd count
        ;;
    last-commit)
        _db_cmd init
        _db_cmd last-commit
        ;;
    *)
        usage
        exit 1
        ;;
esac
