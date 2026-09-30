#!/bin/bash
# Walk a thread ladder for ONE arm inside a SINGLE server lifetime.
# usage: sb-ladder.sh <arm> <tag>
#
# Why one restore per ladder rather than per rung: a 130 GB golden copy per rung
# would cost more wall clock than the measurements. Cost of the shortcut is that
# index bloat accumulates monotonically across the ladder — acceptable because the
# rung ORDER is identical for every arm and pass, so the bias is equal for all of
# them. oltp_read_write is insert/delete balanced, so table sizes stay flat.
set -uo pipefail
. ${SB_ENV:?set SB_ENV to a per-box env file}
. /home/ec2-user/lat16/sb-lib.sh
arm=${1:?usage: sb-ladder.sh <arm> <tag>}
tag=${2:?tag}
RUNGS=${RUNGS:-"32 64 128 256 512 1024"}
R_WARM=${R_WARM:-60}        # discarded per rung
R_TIME=${R_TIME:-120}       # measured per rung
PREWARM=${PREWARM:-180}     # once after restore: fills shared_buffers
TSV=$RES/ladder-${tag}.tsv
mkdir -p "$RES" /tmp/sb-$tag
say() { echo "=== [$(date -u +%T)] $*"; }

say "arm=$arm rungs=[$RUNGS] warm=${R_WARM}s measure=${R_TIME}s prewarm=${PREWARM}s"
say "stop any running postmaster first (restore rm -rf s the datadir)"
$SRV_SSH "bash /home/ec2-user/lat16/pg-srv.sh stop" 2>&1 | tail -1 || true
say "restore golden"
$SRV_SSH "bash /home/ec2-user/lat16/pg-ds.sh restore" 2>&1 | tail -3 || exit 1
say "start server"
$SRV_SSH "bash /home/ec2-user/lat16/pg-srv.sh start $arm" 2>&1 | grep -v "^profiling:" || exit 1

say "prewarm ${PREWARM}s at 64 threads (discarded)"
sysbench --db-driver=pgsql --pgsql-host=$SRV_IP --pgsql-port=$PG_PORT \
  --pgsql-user=$SB_USER --pgsql-password=$PGPASSWORD --pgsql-db=$SB_DB \
  --tables=$SB_TABLES --table-size=$SB_ROWS --threads=64 --time=$PREWARM \
  --rand-type=uniform /usr/local/share/sysbench/oltp_read_write.lua run \
  > /tmp/sb-$tag/$arm.prewarm.log 2>&1 || { say "PREWARM FAILED"; tail -5 /tmp/sb-$tag/$arm.prewarm.log; }

for C in $RUNGS; do
  LAYOUT=$(mp_layout "$C" "$MP_MAX_THREADS")
  NPROC=$(echo $LAYOUT | wc -w)
  say "rung $C threads as [$LAYOUT]"
  rm -f /tmp/sb-$tag/$arm.$C.p*.log
  i=0
  for T in $LAYOUT; do
    i=$((i+1))
    sysbench --db-driver=pgsql --pgsql-host=$SRV_IP --pgsql-port=$PG_PORT \
      --pgsql-user=$SB_USER --pgsql-password=$PGPASSWORD --pgsql-db=$SB_DB \
      --tables=$SB_TABLES --table-size=$SB_ROWS \
      --threads=$T --time=$((R_WARM+R_TIME)) --report-interval=10 \
      --rand-type=uniform /usr/local/share/sysbench/oltp_read_write.lua run \
      > /tmp/sb-$tag/$arm.$C.p$i.log 2>&1 &
  done
  sleep "$R_WARM"
  read -r U0 A0 <<< "$(srv_jiffies)"
  sleep "$R_TIME"
  read -r U1 A1 <<< "$(srv_jiffies)"
  BUSY=$(srv_busy "$U0" "$A0" "$U1" "$A1")
  wait

  for f in /tmp/sb-$tag/$arm.$C.p*.log; do mp_parse "$f" "$R_WARM"; echo; done > /tmp/sb-$tag/$arm.$C.parsed
  read -r TPS QPS P95 NP NI <<< "$(mp_agg < /tmp/sb-$tag/$arm.$C.parsed)"
  ERR=$(grep -ch "PANIC\|FATAL" /tmp/sb-$tag/$arm.$C.p*.log 2>/dev/null | awk '{s+=$1}END{print s+0}')
  SPT=$(awk -v t="$TPS" -v q="$QPS" 'BEGIN{ if(t>0) printf "%.2f", q/t; else print "NA" }')
  CPT=$(awk -v b="$BUSY" -v t="$TPS" -v n="$NVCPU_SRV" \
    'BEGIN{ if(t>0 && b!="NA") printf "%.1f", 1e6*(b/100)*n/t; else print "NA" }')
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$tag" "$arm" "$C" "$NPROC" "$TPS" "$QPS" "$SPT" "$P95" "$BUSY" "$CPT" "$ERR" | tee -a "$TSV"
  say "  -> tps=$TPS busy=${BUSY}% p95=$P95 us-cpu/txn=$CPT procs=$NP err=$ERR"
done

$SRV_SSH "bash /home/ec2-user/lat16/pg-srv.sh stop" 2>&1 | tail -1 || true
say "LADDER_DONE arm=$arm -> $TSV"
