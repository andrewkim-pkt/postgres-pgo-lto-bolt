#!/bin/bash
# lat16 — us-east-2 r8i.16xlarge PG18 sysbench A/B harness. Shared constants.
# Box: 64 vCPU, 495.8 GiB, ONE NUMA node (0-63). No node pinning anywhere.

SRV_IP=<SERVER_PRIVATE_IP>
CLI_IP=<CLIENT_PRIVATE_IP>

NVCPU=64
PG_PORT=5432
PGDATA=/mnt/pgramdisk/pg18sb250
GOLDEN=/var/lib/pg18-lattice/pg18sb250-golden
TMPFS_MNT=/mnt/pgramdisk
TMPFS_SIZE=240G           # ceiling, not a reservation
HP_GB=134                 # 128 GiB shared_buffers + 6 GiB overhead, 1 GiB pages
CONF=/home/ec2-user/lat16/pg16.conf

# clean (non-instrumented) client tools — never use the pgoltob prefix's psql/pgbench
CLEAN_BIN=/opt/pg18-base/bin

SB_DB=sbtest
SB_USER=sbtest
SB_PASS=<SB_PASSWORD>
SB_TABLES=${SB_TABLES:-250}
SB_ROWS=${SB_ROWS:-1000000}

ARM_PREFIX=/opt/pg18-      # arm name -> /opt/pg18-<arm>
