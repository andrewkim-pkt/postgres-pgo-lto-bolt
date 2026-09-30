#!/bin/bash
# lat16 client-side constants. Sourced by sb-*.sh on <SERVER_PRIVATE_IP>.
SRV_IP=<SERVER_PRIVATE_IP>
PG_PORT=5432
NVCPU_SRV=96              # 48xl running at 96 vCPU (CPU options copied from 24xl)
SB_DB=sbtest
SB_USER=sbtest
export PGPASSWORD=<SB_PASSWORD>

SB_TABLES=${SB_TABLES:-250}
SB_ROWS=${SB_ROWS:-3000000}
SB_WARM=${SB_WARM:-600}           # discarded
SB_TIME=${SB_TIME:-180}           # the measured window
SB_CONNS=${SB_CONNS:-400}         # total, fixed across arms (single-point runs)
# Per-process thread cap. 512 is the documented survival edge at 250 tables:
# LuaJIT's ~2 GB per-process heap holds per-table statement arrays in EVERY
# thread's lua_State, and 768+ panics. 512 keeps rungs 32-512 single-process.
MP_MAX_THREADS=${MP_MAX_THREADS:-512}
RUNGS=${RUNGS:-"32 64 128 256 512 1024"}

LAT=/home/ec2-user/lat16
RES=$LAT/results
SRV_SSH="ssh -n -i /home/ec2-user/.ssh/id_lat16 -o BatchMode=yes -o StrictHostKeyChecking=no \
-o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 ec2-user@$SRV_IP"
RUNGS="32 64 128 256 512 1024 1536 2048"   # 48xl: extended, 1024 does not saturate
