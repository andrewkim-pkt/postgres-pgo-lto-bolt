#!/bin/bash
# Mirrored (counterbalanced ABBA) ladder campaign.
# Pass A runs the arms forward, pass B reversed, so every arm's MEAN SEQUENCE
# POSITION is identical and linear time-drift cancels. Report the per-arm SPREAD
# between passes, not just the mean: spread far above the box's placement noise
# means a third point is required before quoting a delta.
# usage: sb-mirror.sh [arm1 arm2 ...]      default: base pgoltob
set -uo pipefail
. /home/ec2-user/lat16/sb-env.sh
TAG=$(date -u +%Y%m%dT%H%M%SZ)
ARMS=("$@"); [ ${#ARMS[@]} -eq 0 ] && ARMS=(base pgoltob)
REV=(); for ((i=${#ARMS[@]}-1;i>=0;i--)); do REV+=("${ARMS[$i]}"); done

echo "=== mirrored ladder campaign $TAG"
echo "=== rungs: ${RUNGS:-32 64 128 256 512 1024}"
echo "=== pass A: ${ARMS[*]}"
echo "=== pass B: ${REV[*]}"
for a in "${ARMS[@]}"; do bash /home/ec2-user/lat16/sb-ladder.sh "$a" "${TAG}-A" || echo "FAILED $a pass A"; done
for a in "${REV[@]}";  do bash /home/ec2-user/lat16/sb-ladder.sh "$a" "${TAG}-B" || echo "FAILED $a pass B"; done

echo
printf "tag\tarm\tthreads\tprocs\ttps\tqps\tstmt/txn\tp95\tbusy%%\tus-cpu/txn\terr\n"
cat "$RES/ladder-${TAG}-A.tsv" "$RES/ladder-${TAG}-B.tsv" 2>/dev/null
echo "MIRROR_DONE $TAG"
