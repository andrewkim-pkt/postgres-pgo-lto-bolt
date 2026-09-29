# Prebuilt binary

The shipped `pgoltob` build — stock PostgreSQL 18.3 compiled with PGO + LTO and relaid out by
`llvm-bolt`. This is the exact install prefix that produced the `+5.5%` to `+8.5%` NOPM result on the
landing page; it was never rebuilt for publication.

| item | value |
|---|---|
| archive | `pg18-pgoltob.tar.xz` |
| archive size | 16,406,964 bytes |
| archive md5 | `86ee207e574675db196187259e53ad38` |
| unpacked size | 71 MB, 1,748 entries |
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
then behaves as neither arm. Keep the prefix intact.

## `pg_config` misreports the flags — ignore it

`pg_config --cflags` on this prefix prints `-fprofile-generate`. That string is stale metadata recorded
in the installed `Makefile.global`, not what built the code: the arm was configured from a tree derived
from the instrumented build, so the recorded string never got rewritten. The actual contents are
verified clean — `nm` finds **zero** `gcov`/profiling symbols in any of the 1,748 files, and the prefix
is byte-for-byte the `pgoltoq` (`-fprofile-use` + LTO + `-g -Wl,-q`) install with exactly one file
replaced: `bin/postgres`, the `llvm-bolt` output. Trust `nm`, not `pg_config`, on this tree.

## Provenance

Built and benchmarked on the r8i.metal-48xl described in the root
[README](../README.md#toolchain-and-source); the profile was collected from HammerDB TPROC-C at 64 VU
for 10 minutes, and BOLT branch samples from the same workload. Because that training ran pinned to a
64-vCPU cell while the benchmark ran unpinned across the whole machine, the profile is matched to the
workload but not to the full-machine load point — see the caveats on the landing page.
