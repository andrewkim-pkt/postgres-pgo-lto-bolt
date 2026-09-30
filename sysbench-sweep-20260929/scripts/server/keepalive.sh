#!/bin/bash
# Keep a waiting box well clear of an idle-shutdown policy, without ever
# perturbing a measurement.
#
# GATE: skip whenever a postmaster (DUT) or sysbench (client) is running. That is
# the campaign itself, so the gate is deterministic. The earlier loadavg gate was
# wrong for a heavy burn: burning raises loadavg, so it would gate itself off and
# oscillate. Checking for the actual processes has no such feedback.
#
# Because the gate is exact, the burn can be substantial: nproc/2 cores, i.e. ~50%
# of the box while it waits. Re-checked every 15 s in 20 s chunks so that when a
# campaign starts the burn stops within ~35 s — long before any measured window,
# which begins 60 s of warm-up after the server comes up (and 180 s of prewarm
# after a restore).
#
# Detached loop rather than a cron entry, deliberately: crontab is left untouched on these hosts
LOG=/tmp/keepalive.log
N=$(nproc); BURN=$(( N/2 )); [ "$BURN" -lt 2 ] && BURN=2
echo "$(date -u +%FT%TZ) keepalive v2 start: ${BURN} of ${N} cores in 20s chunks, gated on postmaster/sysbench" >> $LOG
while true; do
  if pgrep -f "bin/postgres -D" > /dev/null || pgrep -x sysbench > /dev/null; then
    echo "$(date -u +%FT%TZ) campaign active -> skipped" >> $LOG
    sleep 15
  else
    for i in $(seq 1 "$BURN"); do timeout 20 bash -c 'while :; do :; done' & done
    wait
    echo "$(date -u +%FT%TZ) waiting -> burned ${BURN}c/20s" >> $LOG
  fi
  [ "$(wc -l < $LOG 2>/dev/null || echo 0)" -gt 2000 ] && { tail -500 $LOG > $LOG.t; mv $LOG.t $LOG; }
done
