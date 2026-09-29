# Prebuilt binary

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

## Install

```sh
sudo tar -xJf pg18-pgoltob.tar.xz -C /opt
/opt/pg18-pgoltob/bin/postgres --version
```

The archive expands to a single top-level directory `pg18-pgoltob/`, which is the `--prefix` the build
was configured with. Unpack it at `/opt` so the paths match, or re-point `PGDATA`, `PATH` and
`LD_LIBRARY_PATH` at wherever you put it.

## What it will run on

Compiled `-O3 -march=native -mtune=native` on **Xeon 6975P-C (Granite Rapids)** under Amazon Linux
2023. It is portable across machine sizes of the same CPU — all five boxes in the result table ran
this same tree — but `-march=native` means it will fault with an illegal instruction on an older or
different microarchitecture. Rebuild from [the pipeline](../README.md#the-pipeline) for other
hardware.

## Do not mix trees

`lib/*.so` and `share/` in this archive come from the same LTO compilation as `bin/postgres`. Dropping
this `postgres` into a plain `-O3` install prefix, or the reverse, produces a server that starts and
then behaves as neither arm. Keep the prefix intact — but see the section below before using the
bundled client utilities for anything.

## The server is clean; 35 of the bundled client tools are not — read this before benchmarking

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

## Provenance

Built and benchmarked on the r8i.metal-48xl described in the root
[README](../README.md#toolchain-and-source); the profile was collected from HammerDB TPROC-C at 64 VU
for 10 minutes, and BOLT branch samples from the same workload. Because that training ran pinned to a
64-vCPU cell while the benchmark ran unpinned across the whole machine, the profile is matched to the
workload but not to the full-machine load point — see the caveats on the landing page.
