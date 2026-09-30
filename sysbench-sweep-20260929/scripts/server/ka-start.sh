#!/bin/bash
# Idempotent launcher for keepalive.sh.
# Deliberately named ka-start.sh, not start-keepalive.sh: `pgrep -f` matches
# process command lines, so a launcher whose own path contains "keepalive.sh"
# always matches itself and the guard silently never fires.
KA=/home/ec2-user/lat16/keepalive.sh
if pgrep -f "lat16/keepalive\.sh" > /dev/null; then
  echo "ALREADY-RUNNING pids=[$(pgrep -f 'lat16/keepalive\.sh' | tr '\n' ' ')]"
else
  setsid nohup bash "$KA" > /dev/null 2>&1 < /dev/null &
  disown 2>/dev/null || true
  sleep 2
  echo "STARTED pids=[$(pgrep -f 'lat16/keepalive\.sh' | tr '\n' ' ')]"
fi
echo "log: $(head -1 /tmp/keepalive.log 2>/dev/null || echo MISSING)"
