#!/bin/bash
# Start/stop a given arm's server against $PGDATA. pg_ctl -m fast only.
# NOTE: pgoltob's bundled pg_ctl is gcov-instrumented and prints a harmless
# "profiling:...gcda:Cannot open" line at start. It is not the server.
set -uo pipefail
. /home/ec2-user/lat16/pg-env.sh
say() { echo "=== [$(date -u +%T)] $*"; }

case "${1:?usage: pg-srv.sh start <arm>|stop|status|which}" in

start)
  arm=${2:?arm name}
  pfx="${ARM_PREFIX}${arm}"
  [ -x "$pfx/bin/postgres" ] || { say "FAIL: no $pfx/bin/postgres"; exit 1; }
  cp "$CONF" "$PGDATA/postgresql.conf"
  say "starting arm=$arm ($pfx)  md5=$(md5sum "$pfx/bin/postgres" | cut -c1-12)"
  "$pfx/bin/pg_ctl" -D "$PGDATA" -l /tmp/pg-$arm.log -w -t 300 start || { tail -30 /tmp/pg-$arm.log; exit 1; }
  for i in $(seq 1 60); do
    "$CLEAN_BIN/pg_isready" -h /tmp -p "$PG_PORT" -q && break; sleep 1; done
  echo "$arm" > /tmp/lat16-current-arm
  "$CLEAN_BIN/psql" -h /tmp -p "$PG_PORT" -U ec2-user -d postgres -Atc \
    "select current_setting('shared_buffers'), current_setting('huge_pages'), version()" 2>&1
  ;;

stop)
  arm=$(cat /tmp/lat16-current-arm 2>/dev/null || echo base)
  pfx="${ARM_PREFIX}${arm}"
  "$pfx/bin/pg_ctl" -D "$PGDATA" -m fast -w -t 300 stop 2>&1 || true
  say "stopped ($arm)"
  ;;

status)
  echo "arm: $(cat /tmp/lat16-current-arm 2>/dev/null || echo none)"
  "$CLEAN_BIN/pg_isready" -h /tmp -p "$PG_PORT" || true
  pgrep -a -f "bin/postgres -D $PGDATA" | head -3 || echo "no postmaster"
  ;;

which) ls -d ${ARM_PREFIX}* 2>/dev/null | sed "s#${ARM_PREFIX}##" ;;
esac
