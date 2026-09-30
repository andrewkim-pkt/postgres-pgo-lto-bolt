#!/bin/bash
# Replace and restart the keepalive loop.
#
# Must live in a file: any `pkill -f`/`pgrep -f` pattern for "keepalive.sh" typed
# directly into an ssh command also matches that ssh command's own shell, so the
# pkill kills itself before doing anything. Inside this script the pattern never
# appears on my command line, only in the file, and pgrep/pkill match command
# lines rather than file contents. New content arrives as ka-new for the same
# reason.
set -uo pipefail
LAT=/home/ec2-user/lat16
pkill -f "lat16/keepalive\.sh" 2>/dev/null && echo "stopped old loop" || echo "no old loop"
sleep 1
if [ -s "$LAT/ka-new" ]; then mv "$LAT/ka-new" "$LAT/keepalive.sh"; echo "installed new keepalive"; fi
chmod +x "$LAT/keepalive.sh"
rm -f /tmp/keepalive.log
setsid nohup bash "$LAT/keepalive.sh" > /dev/null 2>&1 < /dev/null &
disown 2>/dev/null || true
sleep 2
echo "pids=[$(pgrep -f 'lat16/keepalive\.sh' | tr '\n' ' ')]"
echo "log: $(head -1 /tmp/keepalive.log 2>/dev/null || echo MISSING)"
