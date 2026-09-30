#!/bin/bash
# Dataset lifecycle: tmpfs mount, initdb, golden snapshot, restore.
set -uo pipefail
. /home/ec2-user/lat16/pg-env.sh
say() { echo "=== [$(date -u +%T)] $*"; }

case "${1:?usage: pg-ds.sh mount|init|snapshot|restore|umount|status}" in

mount)
  sudo mkdir -p "$TMPFS_MNT"
  if mount | grep -q " $TMPFS_MNT "; then
    say "already mounted"; else
    sudo mount -t tmpfs -o size=$TMPFS_SIZE,mode=0755 tmpfs "$TMPFS_MNT" || exit 1
    say "mounted tmpfs $TMPFS_SIZE at $TMPFS_MNT"
  fi
  sudo chown "$(id -u):$(id -g)" "$TMPFS_MNT"
  df -h "$TMPFS_MNT" | tail -1
  ;;

init)
  [ -d "$PGDATA" ] && { say "FAIL: $PGDATA exists — remove it first"; exit 1; }
  say "initdb (clean base tools)"
  # no checksum flag: take the PG18 default (checksums ON), same as the 48xl golden
  "$CLEAN_BIN/initdb" -D "$PGDATA" -U ec2-user -E UTF8 >/tmp/initdb.log 2>&1 \
    || { tail -20 /tmp/initdb.log; exit 1; }
  cp "$CONF" "$PGDATA/postgresql.conf"
  cat > "$PGDATA/pg_hba.conf" <<EOF
local   all   all                  trust
host    all   all   127.0.0.1/32   trust
host    all   all   <SERVER_PRIVATE_IP>/16  scram-sha-256
EOF
  say "initdb done: $(du -sh "$PGDATA" | cut -f1)"
  ;;

snapshot)
  sudo mkdir -p "$(dirname "$GOLDEN")"
  sudo chown "$(id -u):$(id -g)" "$(dirname "$GOLDEN")"
  [ -d "$GOLDEN" ] && { say "FAIL: $GOLDEN exists"; exit 1; }
  say "snapshot $PGDATA -> $GOLDEN (EBS-bound)"
  time cp -a "$PGDATA" "$GOLDEN" || exit 1
  say "golden: $(du -sh "$GOLDEN" | cut -f1)"
  ;;

restore)
  [ -d "$GOLDEN" ] || { say "FAIL: no golden at $GOLDEN"; exit 1; }
  rm -rf "$PGDATA"
  say "restore golden -> $PGDATA"
  time cp -a "$GOLDEN" "$PGDATA" || exit 1
  chmod 700 "$PGDATA"
  cp "$CONF" "$PGDATA/postgresql.conf"     # canonical conf always wins
  df -h "$TMPFS_MNT" | tail -1
  ;;

umount) sudo umount "$TMPFS_MNT" && say "unmounted" ;;

status)
  mount | grep " $TMPFS_MNT " || echo "tmpfs: not mounted"
  [ -d "$PGDATA" ] && echo "PGDATA: $(du -sh "$PGDATA" | cut -f1)" || echo "PGDATA: absent"
  [ -d "$GOLDEN" ] && echo "GOLDEN: $(du -sh "$GOLDEN" | cut -f1)" || echo "GOLDEN: absent"
  ;;
esac
