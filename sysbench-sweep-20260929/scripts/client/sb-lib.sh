#!/bin/bash
# Multi-process sysbench driver primitives + server CPU sampling.
#
# WHY MULTI-PROCESS: sysbench's LuaJIT has a per-process ~2 GB ceiling and
# oltp_common.lua materialises per-table statement arrays in EVERY thread's
# lua_State. At 250 tables one process dies above ~512 threads with
# "PANIC: unprotected error in call to Lua API (not enough memory)". The fix is
# more PROCESSES, not more threads.
#
# AGGREGATION RULE: tps and qps ADD across processes. p95 does NOT — percentiles
# cannot be combined, so the WORST is reported and labelled as such. Each
# process's window is averaged BEFORE summing, so a process that emitted more
# report intervals does not get extra weight.

mp_layout() {   # echoes "threads threads ..." for SB_CONNS
  local total=$1 cap=$2 n t i rem
  n=$(( (total + cap - 1) / cap ))
  t=$(( total / n )); rem=$(( total - t*n ))
  for i in $(seq 1 "$n"); do
    if [ "$i" -le "$rem" ]; then echo -n "$((t+1)) "; else echo -n "$t "; fi
  done; echo
}

srv_jiffies() { # total_used total_all  (from /proc/stat line 1)
  $SRV_SSH 'head -1 /proc/stat' 2>/dev/null | awk '{
    idle=$5+$6; all=0; for(i=2;i<=NF;i++) all+=$i; print all-idle, all }'
}

# busy% over the measured window only
srv_busy() { # $1=used0 $2=all0 $3=used1 $4=all1
  awk -v u0="$1" -v a0="$2" -v u1="$3" -v a1="$4" \
    'BEGIN{ d=a1-a0; if(d<=0){print "NA"; exit} printf "%.2f", 100*(u1-u0)/d }'
}

# Parse one sysbench log; average the intervals strictly after SB_WARM.
# prints: tps qps p95_worst nint
mp_parse() { # $1=logfile $2=warm
  awk -v warm="$2" '
    /^\[ *[0-9.]+s *\]/ {
      el=$2; sub(/s$/,"",el); el=el+0
      if (el <= warm) next
      for(i=1;i<=NF;i++){
        if($i=="tps:") t=$(i+1)+0
        if($i=="qps:") q=$(i+1)+0
        if($i=="(ms,95%):") p=$(i+1)+0
      }
      st+=t; sq+=q; n++; if(p>wp) wp=p
    }
    END{ if(n==0){print "0 0 0 0"; exit} printf "%.2f %.2f %.2f %d", st/n, sq/n, wp, n }
  ' "$1"
}

# Sum across per-process parse lines on stdin -> "tps qps p95worst nproc minint"
mp_agg() {
  awk '{ t+=$1; q+=$2; if($3>p)p=$3; n++; if(mi==0||$4<mi)mi=$4 }
       END{ printf "%.2f %.2f %.2f %d %d", t, q, p, n, mi }'
}
