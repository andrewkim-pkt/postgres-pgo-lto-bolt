#!/bin/bash
# lat16 harness — us-east-2 r8i.4xlarge leg. 16 vCPU, 123.8 GiB.
# Sized by halving the 8xl (quarter of the 16xl); ratios held constant.

SRV_IP=<SERVER_PRIVATE_IP>
CLI_IP=<CLIENT_PRIVATE_IP>

NVCPU=16
PG_PORT=5432
PGDATA=/mnt/pgramdisk/pg18sb250
GOLDEN=/var/lib/pg18-lattice/pg18sb250-golden
TMPFS_MNT=/mnt/pgramdisk
TMPFS_SIZE=60G            # ceiling, not a reservation
HP_GB=34                  # 32 GiB shared_buffers + 2 GiB overhead, 1 GiB pages
CONF=/home/ec2-user/lat16/pgbox.conf

CLEAN_BIN=/opt/pg18-base/bin

SB_DB=sbtest
SB_USER=sbtest
SB_PASS=<SB_PASSWORD>
SB_TABLES=${SB_TABLES:-250}        # table COUNT held constant across boxes
SB_ROWS=${SB_ROWS:-250000}         # rows scale with the box

ARM_PREFIX=/opt/pg18-
