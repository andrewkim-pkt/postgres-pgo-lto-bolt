# Prebuilt binaries

Two `pgoltob` builds are published here:

| archive | compiler | result | section |
|---|---|---|---|
| `g15-pg18-pgoltob.tar.xz` | gcc 15.2.0 | +11.95% / +10.30% / +10.54% NOPM, whole-box 48xl / 24xl / 16xl | [gcc 15.2.0 build](#gcc-1520-build-g15-pg18-pgoltobtarxz) |
| `pg18-pgoltob.tar.xz` | gcc 14.2.1 | +5.5% to +8.5% NOPM on five machine sizes | [gcc 14.2.1 build](#gcc-1421-build-pg18-pgoltobtarxz) |

Do not mix files from the two trees.

## gcc 15.2.0 build: `g15-pg18-pgoltob.tar.xz`

Stock PostgreSQL 18.3 built with gcc 15.2.0, using PGO + LTO, then relaid out by `llvm-bolt` 18.1.3.
This is the exact install prefix behind the
[gcc 15.2.0 whole-box result](../README.md#result-whole-box-hammerdb-tproc-c-gcc-1520-arms-vs-base).
It was copied unchanged to the 48xl, 24xl and 16xl, and it was not rebuilt for publication.

| item | value |
|---|---|
| archive | `g15-pg18-pgoltob.tar.xz` |
| archive size | 37,641,168 bytes |
| archive md5 | `28724b897fe3cf92d649bc15ef47a283` |
| archive sha256 | `5ca027d5515a572635b6eb3b7c263e342e662a8d4978ad527cd972af4dd68c1d` |
| unpacked size | 150 MB, 1,655 files (not stripped, includes debug info) |
| `bin/postgres` md5 | `2b4d8844dc0cb5d8c4e08df9c1f63610` |
| `bin/postgres` size | 77,992,928 bytes |
| version string | `postgres (PostgreSQL) 18.3` |
| built | 2026-09-30 |

### Install

```sh
sudo tar -xJf g15-pg18-pgoltob.tar.xz -C /opt --no-same-owner
/opt/g15-pg18-pgoltob/bin/postgres --version
```

The archive unpacks to a single directory, `g15-pg18-pgoltob/`.

`pg_config --configure` reports `--prefix=/opt/g15-pg18-pgoltoq`. That is the prefix of the BOLT input
build (`-g -Wl,-q`), which this tree was copied from before `bin/postgres` was replaced with the
`llvm-bolt` output. PostgreSQL finds `lib/` and `share/` relative to its own binary, so the tree works
wherever you unpack it. It ran from `/opt/g15-pg18-pgoltob` in every measurement.

### What it will run on

It is compiled `-O3 -march=native -mtune=native` on a **Xeon 6975P-C (Granite Rapids)** under Amazon
Linux 2023, so it will crash with an illegal instruction on any other microarchitecture. It also needs
the system glibc and OpenSSL. It does not depend on the gcc 15 runtime libraries.

### Instrumentation: none

This tree does **not** have the problem described for the gcc 14.2.1 tree below. Every binary was linked
from the `-fprofile-use` build. `bin/postgres`, `pgbench`, `psql`, `pg_ctl` and the libraries contain 0
`gcov` symbols. `pg_config --cflags` reports the flags of the optimised build
(`-fprofile-use -fprofile-correction -fprofile-partial-training ... -flto=96 -ffat-lto-objects -g`).

```sh
readelf -sW bin/postgres | grep -c gcov     # 0
readelf -sW bin/pgbench  | grep -c gcov     # 0
```

### Provenance

It was built on an r8i.metal-48xl, following the gcc 15.2.0 recipe in the root
[README](../README.md#step-by-step). The PGO profile and the BOLT samples both come from HammerDB
TPROC-C. All measurements ran on the whole machine, with PostgreSQL unpinned.

## gcc 14.2.1 build: `pg18-pgoltob.tar.xz`

The shipped `pgoltob` build — stock PostgreSQL 18.3 compiled with PGO + LTO and relaid out by
`llvm-bolt`. This is the exact install prefix that produced the `+5.5%` to `+8.5%` NOPM result on the
landing page; it was never rebuilt for publication.

| item | value |
|---|---|
| archive | `pg18-pgoltob.tar.xz` |
| archive size | 16,406,964 bytes |
| archive md5 | `86ee207e574675db196187259e53ad38` |
| unpacked size | 71 MB, 1,655 files |
| `bin/postgres` md5 | `d27408aa2c408e0c4c0757902ea52668` |
| `bin/postgres` size | 17,886,432 bytes |
| version string | `postgres (PostgreSQL) 18.3` |
| built | 2026-09-08 |

### Install

```sh
sudo tar -xJf pg18-pgoltob.tar.xz -C /opt
/opt/pg18-pgoltob/bin/postgres --version
```

The archive expands to a single top-level directory `pg18-pgoltob/`, which is the `--prefix` the build
was configured with. Unpack it at `/opt` so the paths match, or re-point `PGDATA`, `PATH` and
`LD_LIBRARY_PATH` at wherever you put it.

### What it will run on

Compiled `-O3 -march=native -mtune=native` on **Xeon 6975P-C (Granite Rapids)** under Amazon Linux
2023. It is portable across machine sizes of the same CPU — all five boxes in the result table ran
this same tree — but `-march=native` means it will fault with an illegal instruction on an older or
different microarchitecture. Rebuild from [the pipeline](../README.md#the-pipeline) for other
hardware.

### Do not mix trees

`lib/*.so` and `share/` in this archive come from the same LTO compilation as `bin/postgres`. Dropping
this `postgres` into a plain `-O3` install prefix, or the reverse, produces a server that starts and
then behaves as neither arm. Keep the prefix intact — but see the section below before using the
bundled client utilities for anything.

### The server is clean; 35 of the bundled client tools are not — read this before benchmarking

The PGO arms in this campaign were built by reusing the instrumented `pgogen` source tree, and the
client programs were never relinked from it. So this prefix is a mix, and it matters:

| component | state |
|---|---|
| `bin/postgres` — the server, the only thing benchmarked | **clean.** 0 `gcov` symbols, 0 `.gcda` strings — identical status to the `-O3` baseline |
| `lib/*.so`, `lib/postgresql/*.so` | clean |
| `bin/initdb` | clean |
| 35 other `bin/*` utilities | **instrumented** (`-fprofile-generate` leftovers), including `psql`, `pg_ctl`, `pg_dump`, `pg_restore`, `pg_upgrade`, `pg_config` and **`pgbench`** |

**Do not measure anything with the bundled `pgbench` or `psql`.** They are profile-generating builds,
several times slower than a normal client, and they append to `.gcda` counters on every exit. Take
those from a plain build. `pg_ctl` is instrumented too, but it only starts and stops the server, so it
costs nothing in a measured run — which is exactly why this went unnoticed at benchmark time.

None of this touches the published numbers: the measured path is HammerDB's own PostgreSQL driver
talking to `bin/postgres`, and that binary carries no instrumentation.

Verify any of it yourself:

```sh
readelf -sW bin/postgres | grep -c gcov     # 0
readelf -sW bin/pgbench  | grep -c gcov     # 1497
```

`pg_config --cflags` prints `-fprofile-generate` on this prefix for the same reason — stale metadata
recorded in the installed `Makefile.global`, plus `pg_config` itself being one of the instrumented
copies. It does not describe how `bin/postgres` was compiled.

The archive is published **unaltered** rather than cleaned up, because its value is that it is the exact
tree that produced the numbers. Substituting binaries into it would break that guarantee. Apart from
`bin/postgres` — the `llvm-bolt` output — it is byte-for-byte the `pgoltoq` (`-fprofile-use` + LTO +
`-g -Wl,-q`) install: 1,655 files, one differs.

### Provenance

Built and benchmarked on the r8i.metal-48xl described in the root
[README](../README.md#toolchain-and-source); the profile was collected from HammerDB TPROC-C at 64 VU
for 10 minutes, and BOLT branch samples from the same workload. Because that training ran pinned to a
64-vCPU cell while the benchmark ran unpinned across the whole machine, the profile is matched to the
workload but not to the full-machine load point — see the caveats on the landing page.
