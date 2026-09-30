#!/bin/bash
# lat16 harness — us-east-2 r8i.8xlarge leg. 32 vCPU, 247.7 GiB.
# Sized by halving the 16xl: every ratio (dataset:shared_buffers:RAM,
# WAL:dataset) is held constant so only absolute scale changes.

SRV_IP=<SERVER_PRIVATE_IP>
CLI_IP=<CLIENT_PRIVATE_IP>

NVCPU=32
PG_PORT=5432
PGDATA=/mnt/pgramdisk/pg18sb250
GOLDEN=/var/lib/pg18-lattice/pg18sb250-golden
TMPFS_MNT=/mnt/pgramdisk
TMPFS_SIZE=120G           # ceiling, not a reservation
HP_GB=68                  # 64 GiB shared_buffers + 4 GiB overhead, 1 GiB pages
CONF=/home/ec2-user/lat16/pgbox.conf

CLEAN_BIN=/opt/pg18-base/bin

SB_DB=sbtest
SB_USER=sbtest
SB_PASS=<SB_PASSWORD>
SB_TABLES=${SB_TABLES:-250}        # table COUNT held constant across boxes
SB_ROWS=${SB_ROWS:-500000}         # rows scale with the box

ARM_PREFIX=/opt/pg18-
