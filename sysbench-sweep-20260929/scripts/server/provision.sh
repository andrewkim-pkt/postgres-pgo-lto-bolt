#!/bin/bash
# Bare AL2023 box -> ready-to-measure PG18 sysbench DUT. Detached; ~30 min.
# Reads all sizing from lat16/pg-env.sh, so the same script serves every box size.
set -uo pipefail
LAT=/home/ec2-user/lat16
. $LAT/pg-env.sh
say() { echo "=== [$(date -u +%T)] $*"; }
J=$NVCPU

say "step 1: packages (make -j$J)"
sudo dnf -y install gcc14 gcc14-c++ gcc make git tar xz bzip2 automake libtool pkgconfig \
  readline-devel zlib-devel libicu-devel openssl-devel libzstd-devel lz4-devel bison flex perl \
  libpq-devel numactl perf sysstat > /tmp/dnf.log 2>&1 || { tail -5 /tmp/dnf.log; exit 1; }
gcc14-gcc --version | head -1

say "step 2: published pgoltob from GitHub (expect bin/postgres md5 d27408aa2c40)"
cd /home/ec2-user && rm -rf repo
git clone --depth 1 https://github.com/andrewkim-pkt/postgres-pgo-lto-bolt.git repo >/dev/null 2>&1 \
  || { echo "FAIL: clone"; exit 1; }
md5sum repo/binaries/pg18-pgoltob.tar.xz
sudo rm -rf /opt/pg18-pgoltob
sudo tar -xJf repo/binaries/pg18-pgoltob.tar.xz -C /opt || exit 1
/opt/pg18-pgoltob/bin/postgres --version
md5sum /opt/pg18-pgoltob/bin/postgres

say "step 3: base build — stock 18.3, -O3 -march=native -mtune=native, gcc14-gcc"
cd /home/ec2-user
[ -f postgresql-18.3.tar.bz2 ] || curl -sSLO https://ftp.postgresql.org/pub/source/v18.3/postgresql-18.3.tar.bz2
rm -rf postgresql-18.3 && tar xf postgresql-18.3.tar.bz2 && cd postgresql-18.3 || exit 1
./configure --prefix=/opt/pg18-base --with-openssl --with-readline \
  CC=gcc14-gcc CFLAGS="-O3 -march=native -mtune=native" > /tmp/conf.log 2>&1 \
  || { tail -10 /tmp/conf.log; exit 1; }
make -j$J > /tmp/make.log 2>&1 || { tail -10 /tmp/make.log; exit 1; }
sudo make install > /tmp/inst.log 2>&1 || { tail -10 /tmp/inst.log; exit 1; }
/opt/pg18-base/bin/postgres --version
md5sum /opt/pg18-base/bin/postgres

say "step 4: sysbench (used ONLY to load the dataset over the local socket)"
cd /home/ec2-user && rm -rf sysbench
git clone --depth 1 https://github.com/akopytov/sysbench.git >/dev/null 2>&1 || { echo "FAIL: sb clone"; exit 1; }
cd sysbench && ./autogen.sh >/tmp/sb-auto.log 2>&1 \
  && ./configure --without-mysql --with-pgsql >/tmp/sb-conf.log 2>&1 \
  && make -j$J >/tmp/sb-make.log 2>&1 \
  && sudo make install >/tmp/sb-inst.log 2>&1 || { echo "FAIL: sysbench build"; exit 1; }
sysbench --version

say "step 5: reserve $HP_GB x 1GiB huge pages"
bash $LAT/pg-hp.sh reserve || exit 1

say "step 6: tmpfs $TMPFS_SIZE + initdb"
bash $LAT/pg-ds.sh mount || exit 1
rm -rf "$PGDATA"
bash $LAT/pg-ds.sh init || exit 1

say "step 7: start base, load $SB_TABLES tables x $SB_ROWS rows"
bash $LAT/pg-srv.sh start base 2>&1 | grep -v "^profiling:" || exit 1
bash $LAT/pg-prep-local.sh || exit 1

say "step 8: clean shutdown + golden snapshot"
bash $LAT/pg-srv.sh stop
rm -rf "$GOLDEN"
bash $LAT/pg-ds.sh snapshot || exit 1
bash $LAT/pg-ds.sh status
echo PROVISION_DONE
