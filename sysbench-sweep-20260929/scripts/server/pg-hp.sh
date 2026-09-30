#!/bin/bash
# Reserve 1 GiB huge pages. One NUMA node on this box, so no per-node split.
set -uo pipefail
. /home/ec2-user/lat16/pg-env.sh
GB=${GB:-$HP_GB}
SYS=/sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages

case "${1:-status}" in
  reserve)
    [ -w "$SYS" ] || [ -e "$SYS" ] || { echo "FAIL: no 1GiB hugepage support at $SYS"; exit 1; }
    echo "requesting $GB x 1GiB"
    echo "$GB" | sudo tee "$SYS" >/dev/null
    got=$(cat "$SYS")
    echo "granted: $got"
    [ "$got" -ge "$GB" ] || { echo "FAIL: only $got of $GB granted (fragmentation)"; exit 1; }
    ;;
  release)
    echo 0 | sudo tee "$SYS" >/dev/null; echo "released" ;;
  status)
    echo "nr_hugepages(1GiB): $(cat "$SYS" 2>/dev/null || echo n/a)"
    grep -E "^HugePages_Total|^HugePages_Free|^Hugepagesize" /proc/meminfo ;;
esac
