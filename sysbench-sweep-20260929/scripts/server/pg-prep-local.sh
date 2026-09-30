#!/bin/bash
# Load the 250 x 1M oltp_read_write dataset over the server's UNIX SOCKET.
# Used instead of the client because the us-east-2 SG blocks 5433; loading
# locally is also faster and produces a byte-equivalent dataset.
set -uo pipefail
. /home/ec2-user/lat16/pg-env.sh
say() { echo "=== [$(date -u +%T)] $*"; }
PSQL="$CLEAN_BIN/psql -h /tmp -p $PG_PORT -U ec2-user"

say "role + db"
$PSQL -d postgres -v ON_ERROR_STOP=0 \
  -c "create role $SB_USER login password '$SB_PASS'" \
  -c "create database $SB_DB owner $SB_USER" 2>&1 | grep -v "^NOTICE" || true

say "prepare $SB_TABLES tables x $SB_ROWS rows (unix socket, 64 threads)"
time sysbench --db-driver=pgsql --pgsql-host=/tmp --pgsql-port=$PG_PORT \
  --pgsql-user=$SB_USER --pgsql-password=$SB_PASS --pgsql-db=$SB_DB \
  --tables=$SB_TABLES --table-size=$SB_ROWS --threads=64 \
  /usr/local/share/sysbench/oltp_read_write.lua prepare 2>&1 | tail -4

say "vacuum analyze (makes the golden deterministic and well-planned)"
time $PSQL -d $SB_DB -c "vacuum analyze" 2>&1 | tail -2

say "checkpoint"
$PSQL -d $SB_DB -c "checkpoint" 2>&1 | tail -1

say "sizes"
$PSQL -d $SB_DB -Atc "select count(*) from pg_class where relname like 'sbtest%' and relkind='r'"
$PSQL -d $SB_DB -Atc "select pg_size_pretty(sum(pg_total_relation_size(oid))) from pg_class
   where relname like 'sbtest%' and relkind='r'"
$PSQL -d $SB_DB -Atc "select pg_size_pretty(pg_database_size('$SB_DB'))"
df -h "$TMPFS_MNT" | tail -1
echo "PREP_LOCAL_DONE"
