# postgres-pgo-lto-bolt

Build recipe and measurements for PGO + LTO + BOLT applied to **stock PostgreSQL 18.3**, benchmarked
with HammerDB 4.7 TPROC-C on Xeon 6975P-C (Granite Rapids) across five machine sizes.

**Result: +5.5% to +8.5% NOPM** over a plain `-O3 -march=native` build, measured conservatively
against the better of two baseline iterations. The optimised build won every one of the 20
box × virtual-user cells tested. The tables are at the bottom of this page — [how the methodology was
chosen](#1-choosing-the-methodology--ten-arms-on-one-machine), the
[five-machine result](#2-final-result--base-vs-pgoltob-on-five-machine-sizes) and the
[summary](#3-summary) — with the per-machine breakdown in [RESULTS.md](RESULTS.md).

The build itself is published in [binaries/](binaries/): `pg18-pgoltob.tar.xz`, `bin/postgres` md5
`d27408aa2c408e0c4c0757902ea52668`, for Xeon 6975P-C on Amazon Linux 2023.

**Also on sysbench:** the same binary, untouched, was measured on sysbench `oltp_read_write` across five r8i
sizes. It is **+7 to +12% tps** where the server is CPU-bound, and cheaper per transaction almost everywhere. See
[Sysbench benchmark of PostgreSQL 18.3 with the HammerDB-trained HWPGO build](#sysbench-benchmark-of-postgresql-183-with-the-hammerdb-trained-hwpgo-build-pgo--lto--bolt).

## Contents

| file | what it is |
|---|---|
| [BUILD-OPTIONS.md](BUILD-OPTIONS.md) | the same pipeline as below, plus the failure modes behind each flag and the gates that catch a silently-wrong build |
| [RESULTS.md](RESULTS.md) | NOPM for both arms at every virtual-user count on every box, plus what the data does and does not support |
| [scripts/](scripts/) | the scripts that produced it |
| [binaries/](binaries/) | the shipped `pgoltob` build itself, as an install prefix — the same tree that produced the numbers below |
| [sysbench-sweep-20260929/](sysbench-sweep-20260929/) | sysbench `oltp_read_write` sweep of this binary on five r8i sizes: raw per-run data, per-box configs, harness |

---

# Sysbench benchmark of PostgreSQL 18.3 with the HammerDB-trained HWPGO build (PGO + LTO + BOLT)

**Question:** the published `pgoltob` binary was profile-trained on HammerDB TPROC-C. Does it also speed up a
different OLTP workload, sysbench `oltp_read_write`, that it was never trained on?

**Answer: yes, once the server is CPU-bound.** On single-NUMA-node boxes the unmodified published binary is
**+7 to +12% tps** over a plain `-O3 -march=native` build at the saturated thread counts. On 31 of the 32
box x thread cells it needs less CPU per transaction, typically **5-10% less**. Where the server is not CPU-bound, or
is limited by lock contention (the 2- and 3-node boxes above ~1024 threads), that saving does not turn into
throughput.

Measured 2026-09-29 on five AWS r8i sizes (Xeon 6975P-C, us-east-2), 32 to 1024 threads (to 2048 on the
48xlarge), mirrored A/B/B/A order, 0 errors in all 128 runs. Raw data, per-box configs and the harness are
in [`sysbench-sweep-20260929/`](sysbench-sweep-20260929/).

## Binaries under test

| arm | what it is | `bin/postgres` md5 |
|---|---|---|
| `base` | stock PostgreSQL 18.3, `-O3 -march=native -mtune=native`, gcc 14.2.1 (`gcc14-gcc`), built on each box | `f1b62bb68d47...` |
| `pgoltob` | the published PGO + LTO + BOLT build, trained on HammerDB TPROC-C, installed unmodified from [`binaries/pg18-pgoltob.tar.xz`](https://github.com/andrewkim-pkt/postgres-pgo-lto-bolt/tree/main/binaries) | `d27408aa2c40...` |

`base` built independently on all five boxes came out byte-identical, so the baseline is the same binary everywhere.

## Result: tps, pgoltob vs base

Each cell is the mean of both passes. **Bold** = distinguishable: the delta is larger than the pass-A-to-pass-B
spread of both arms. ° = not distinguishable from base.

| threads | 4xlarge<br>16 vCPU, 1 node | 8xlarge<br>32 vCPU, 1 node | 16xlarge<br>64 vCPU, 1 node | 24xlarge<br>96 vCPU, 2 nodes | 48xlarge\*<br>96 vCPU, 3 nodes |
|---|---|---|---|---|---|
| 32 | **+4.27%** | +0.72% ° | -0.05% ° | -0.34% ° | +0.75% ° |
| 64 | **+4.84%** | **+3.09%** | **+1.85%** | +3.14% ° | **+7.67%** |
| 128 | **+8.92%** | **+3.59%** | **+3.20%** | **+3.62%** | **+7.10%** |
| 256 | **+8.21%** | **+7.00%** | **+6.58%** | +4.38% ° | -0.27% ° |
| 512 | **+11.81%** | **+7.69%** | **+7.31%** | **+3.23%** | **+4.80%** |
| 1024 | **+8.62%** | **+10.70%** | **+6.96%** | **+4.72%** | **-1.64%** |
| 1536 | - | - | - | - | **+14.03%** |
| 2048 | - | - | - | - | **-2.22%** |
| **mean, 32-1024** | **+7.78%** | **+5.47%** | **+4.31%** | **+3.13%** | **+3.07%** |
| base peak | 13,895 tps @ 128 | 28,814 @ 256 | 53,550 @ 512 | 69,352 @ 512 | 65,155 @ 1024 |

\* The 48xlarge ran with **96 vCPU, not 192**: it was launched from the 24xlarge with "Launch more like this",
which copied the 24xlarge CPU options (48 cores x 2 threads). It is effectively a 24xlarge CPU with 1.5 TiB RAM
and 3 NUMA nodes (SNC-3). A run at the full 192 vCPU is still to do.

## Result: CPU per transaction, pgoltob vs base

Server CPU-microseconds per transaction (server busy fraction x vCPU / tps). Negative = cheaper.

| threads | 4xlarge | 8xlarge | 16xlarge | 24xlarge | 48xlarge\* |
|---|---|---|---|---|---|
| 32 | -10.0% | -5.9% | -6.9% | -5.1% | -9.1% |
| 64 | -6.7% | -9.2% | -9.1% | -6.6% | -8.5% |
| 128 | -9.1% | -6.2% | -7.7% | -3.5% | -8.3% |
| 256 | -7.6% | -7.4% | -6.4% | -3.7% | -5.6% |
| 512 | -10.6% | -7.2% | -8.0% | -5.4% | -8.1% |
| 1024 | -7.9% | -9.7% | -6.8% | -5.0% | -0.2% |
| 1536 | - | - | - | - | -13.5% |
| 2048 | - | - | - | - | +1.5% |

Base server busy % at each rung is in [`results/summary.tsv`](sysbench-sweep-20260929/results/summary.tsv).

## Reading the result

- **The binary is consistently cheaper per transaction**: cheaper on 31 of the 32 box x thread cells, typically
  by 5-10%.
- **On the single-node boxes that saving becomes throughput once the server is CPU-bound.** Below ~70% server
  busy the gain there is 0-5%; at 97-100% busy it is +7 to +12%. The 48xlarge is the exception at low load:
  +7% at 64-128 threads while only 26-30% busy.
- **Multi-node boxes gain less.** The 24xlarge (2 nodes) and 48xlarge (3 nodes) stop at 88-92% busy, and the
  pass-to-pass spread widens to as much as 5.5% (restart-to-restart memory placement varies across nodes). On
  the 48xlarge above 1024 threads the run is lock-contention-bound, where the CPU-per-transaction saving itself
  disappears (-0.2% at 1024, +1.5% at 2048). In that regime the order of the two arms is set by contention,
  not code layout, so the curve zig-zags. Both passes reproduce each rung within ~2%, so the zig-zag is real.
- **Consistent with earlier sysbench campaigns.** On a us-east-1 r8i.metal-48xl at 1200 connections and 78%
  busy the same binary was a null result (-0.66%, inside noise). The sysbench-TRAINED lattice on a us-east-2
  48xlarge at 60-68% busy put `pgoltob` at +4.11% with -12.8% CPU per transaction. Neither run saturated the server.

## Test setup

| | |
|---|---|
| servers | r8i.4xlarge / 8xlarge / 16xlarge / 24xlarge / 48xlarge, Xeon 6975P-C, 480 MiB L3 per socket, Amazon Linux 2023 |
| client | one r8i.16xlarge, same AZ (us-east-2c), sysbench 1.1.0 (git master, pgsql driver), never on the server |
| data dir | tmpfs, restored from an EBS golden copy before every arm-pass; `shared_buffers` on 1 GiB huge pages |
| workload | `oltp_read_write`, 250 tables, uniform random, 20 statements per transaction (checked on every rung) |
| per rung | 60 s warm-up + 120 s measured, 10 s report interval |
| per arm-pass | restore golden, start, 180 s prewarm at 64 threads (discarded), then all rungs in one server lifetime |
| order | pass A `base, pgoltob`, pass B `pgoltob, base`, so both arms have the same mean position in time |

**Sizing: every absolute scales with the box, every ratio is held.** Row count scales, table count does not.
Keeping 250 tables everywhere keeps the relation count, index count and lock-partition spread identical, so
only the data volume changes, not the contention structure.

| | 4xlarge | 8xlarge | 16xlarge | 24xlarge | 48xlarge |
|---|---|---|---|---|---|
| vCPU / RAM | 16 / 124 GiB | 32 / 248 GiB | 64 / 496 GiB | 96 / 743 GiB | 96\* / 1488 GiB |
| rows per table (x250) | 250k | 500k | 1M | 1.5M | 3M |
| golden data dir | 32 GB | 63 GB | 126 GB | 189 GB | 377 GB |
| `shared_buffers` / 1 GiB huge pages | 32GB / 34 | 64GB / 68 | 128GB / 134 | 192GB / 201 | 384GB / 402 |
| `max_wal_size` / `min_wal_size` | 16GB / 2GB | 32GB / 4GB | 64GB / 8GB | 96GB / 12GB | 192GB / 24GB |
| `max_connections` | 1500 | 1500 | 1500 | 1500 | 2500 |

Everything that shapes the workload is identical on all boxes: `synchronous_commit=off`, `full_page_writes=off`,
`wal_level=minimal`, `wal_buffers=1GB`, `checkpoint_timeout=30min`, `jit=off`, planner costs, autovacuum,
data checksums on (PG18 default). Full configs: [`config/`](sysbench-sweep-20260929/config/).

**Metrics.** tps and qps add across sysbench processes. p95 does not, so the worst process is reported.
Each process is averaged over its own measured intervals before summing. Server busy % comes from
`/proc/stat` on the server, sampled at the start and end of the measured window only.

**One sysbench process holds at most 512 threads.** At 250 tables each thread keeps per-table prepared-statement
state in its own LuaJIT heap, and above ~512 threads a single process runs out of LuaJIT memory. 1024 threads
run as 2 x 512, 1536 as 3 x 512, 2048 as 4 x 512.

## Files

```
sysbench-sweep-20260929/
  results/per-pass.tsv    every run: box, pass, arm, threads, procs, tps, server busy %, worst p95, CPU us/txn, errors
  results/summary.tsv     both passes side by side, mean, delta, per-arm spread, distinguishable flag
  config/<instance>/      pg-env.sh (sizing) and postgresql.conf for each box
  scripts/server/         provision.sh (bare AL2023 -> ready DUT), pg-hp.sh, pg-ds.sh, pg-srv.sh, pg-prep-local.sh,
                          keepalive.sh + ka-start.sh / ka-restart.sh (keep a waiting box above an idle-shutdown policy)
  scripts/client/         sb-env*.sh (per box), sb-lib.sh, sb-ladder*.sh (one arm, all rungs), sb-mirror*.sh (A/B/B/A)
```

Private addresses are replaced by `<SERVER_PRIVATE_IP>` / `<CLIENT_PRIVATE_IP>` and the database password by
`<SB_PASSWORD>`. Set them before running.

---

# The pipeline

Four builds and a rewrite: instrument → train → rebuild with the profile → sample branches → relayout.

```
pgogen   -fprofile-generate        instrumented, used only to produce .gcda
   |
   |  training run: HammerDB TPROC-C, 64 VU, 10 min
   v
pgolto   -fprofile-use + LTO       the benchmarked PGO+LTO binary
pgoltoq  same + -g -Wl,-q          identical codegen; this is BOLT's input
   |
   |  perf record -b (branches) while serving load
   v
pgoltob  llvm-bolt rewrite         the shipped binary
```

## Toolchain and source

| item | value |
|---|---|
| compiler | GCC 14.2.1 (`gcc14-gcc` on Amazon Linux 2023), on the database host |
| LTO archivers | `AR=gcc14-gcc-ar RANLIB=gcc14-gcc-ranlib NM=gcc14-gcc-nm` |
| BOLT | `perf2bolt` / `llvm-bolt`, on a separate Ubuntu host |
| source | stock PostgreSQL 18.3 (`62d6c7d3df6`, "Stamp 18.3."), `NUM_XLOGINSERT_LOCKS` at its stock 8 |
| tree export | `git archive <rev> \| tar -x` into a fresh directory, one per arm |
| parallelism | `make -j192`, `-flto=96` |

```
COMMON = -O3 -march=native -mtune=native
LTO    = -flto=96 -ffat-lto-objects
PGOUSE = -fprofile-use -fprofile-correction -fprofile-partial-training -Wno-missing-profile
```

The configure line is byte-identical for every arm — `CFLAGS`/`LDFLAGS` are the only difference, so
the measurement is of the optimisation options and not of the build configuration:

```
./configure --prefix=$PREFIX --with-openssl --with-readline CC=$CC CFLAGS="…" LDFLAGS="…"
```

No `--with-llvm`. JIT-generated code is untouched by BOLT, and its anonymous runtime code pollutes
the LBR recordings that feed `perf2bolt`.

## 1. Instrumented build

```
CFLAGS  = -O3 -march=native -mtune=native -fprofile-generate -fprofile-update=prefer-atomic
LDFLAGS = -fprofile-generate
make      enable_coverage=yes
```

`-fprofile-update=prefer-atomic` keeps counters sane when several hundred backends touch the same
`.gcda` — PostgreSQL forks one backend per connection.

`enable_coverage=yes` is a **make variable, not a compiler flag**, and adds no flags. It only skips
libpq's `libpq-refs-stamp` rule, which fails the build when `libpq.so` references anything calling
`exit()` — and `-fprofile-generate` links gcov's at-exit dumper, so it does. Needed again at
`make install`. Side effect: it hooks `clean-coverage` into `make clean`, so **never `make clean`
this tree** between training and the `-fprofile-use` builds.

## 2. Training run

```
VU         = 64      # = core count of the training cell, NOT the binary's peak VU
warehouses = 1536
rampup     = 3 min
duration   = 10 min
```

- **Train at core count, deliberately.** Training at the optimised binary's peak VU piles samples
  into lock-wait paths instead of real work; that cost BOLT 2.5% in an earlier campaign.
- **Delete the pre-existing `.gcda` first.** The instrumented build compiles and then *runs*
  build-time tools, which dump counters at the same object paths the backends will use. Those are
  build-tool counters, not training data.
- **Shut down gracefully.** `pg_ctl -m immediate` sends SIGQUIT, exit handlers never run, no backend
  dumps its counters, and **the entire training run is lost**.

## 3. Optimised build, and BOLT's input twin

Two builds from one profile. `pgolto` is benchmarked; `pgoltoq` is what BOLT consumes.

```
pgolto    CFLAGS  = $COMMON $PGOUSE -flto=96 -ffat-lto-objects
          LDFLAGS = -flto=96 -ffat-lto-objects

pgoltoq   CFLAGS  = $COMMON $PGOUSE -flto=96 -ffat-lto-objects -g
          LDFLAGS = -flto=96 -ffat-lto-objects -Wl,-q
```

`-g` gives BOLT its `.debug_line`; `-Wl,-q` retains relocations so `.rela.text` survives the link —
`llvm-bolt` rejects the binary without it. Neither changes codegen.

- **`-fprofile-use` takes no `=path`.** GCC looks for each `.gcda` beside its own object file, which
  is why these builds must reuse the instrumented tree in place.
- **`-fprofile-correction` is mandatory.** Multi-process counter merging leaves inconsistent counts
  and GCC hard-errors without it.
- **`-fprofile-partial-training`** keeps never-trained functions at `-O3` instead of size-optimising
  them; a TPROC-C workload never touches most of PostgreSQL.
- **`-ffat-lto-objects` is required, not cautious.** The build runs objects through `ar`/`ranlib`
  *and* executes generated tools, so each `.o` must carry both IR and real machine code.
- **`gcc-ar`/`gcc-ranlib`/`gcc-nm` must match the compiler.** A mismatch loads the wrong plugin for
  the IR in `libpgcommon.a`/`libpgport.a` and either fails the link or silently drops cross-module
  inlining — which reads as "LTO did nothing".

Reusing the tree means deleting build products while keeping `*.gcda`/`*.gcno`. Two deletions are
load-bearing and neither is obvious — see [BUILD-OPTIONS.md](BUILD-OPTIONS.md) for the measurements:
**`objfiles.txt`** (a per-directory build stamp that makes `make` compile nothing and then fail the
link) and **every linked program**, not just `src/backend/postgres` (otherwise instrumented tools
survive into the new prefix, and an instrumented `psql` or `pg_ctl` writes `.gcda` *back into the
training tree*).

## 4. Sampling: `perf record`

On the database host, against the `-g -Wl,-q` twin while it serves load:

```
perf record -b -z1 --aio=4 -c 100003 -e branches:u \
    -C <cpu-list> -m 128M --proc-map-timeout 5000 -o perf.data -- sleep 180
```

Branch-driven, not cycles-driven: `perf2bolt` only wants taken-branch source/target pairs. `-z1`
compresses, because an uncompressed 180 s branch record on 64 vCPU is tens of GB; `--aio=4` keeps the
writer off the profiled CPUs. `nmi_watchdog` is disabled for the window and restored afterwards.

Window: 6 min of load, 30 s settle after rampup, 180 s recorded. The record must finish **inside** the
load window, or you capture teardown instead of steady state.

For contrast, the AutoFDO arms sample differently, because `create_gcov`'s edge inference wants a
cycles-driven sample with a branch stack:

```
perf record -e cycles:u -j any,u -c 400009 \
    -C <cpu-list> -m 128M --proc-map-timeout 5000 -o perf.data -- sleep 180
```

## 5. Rewrite: `perf2bolt` and `llvm-bolt`

```
perf2bolt -p perf.data -o profile.fdata ./postgres

llvm-bolt ./postgres -o postgres.bolt -data=profile.fdata \
    -reorder-blocks=ext-tsp \
    -reorder-functions=cdsort \
    -split-functions \
    -split-all-cold \
    -split-eh \
    -dyno-stats \
    --update-debug-sections
```

**Deliberately excluded: `--icf`, `--icp=all`, `--hugify`.** That richer set measured a wash-to-loss
on this workload.

Two `perf2bolt` constraints that fail quietly rather than loudly:

- **The input must be named exactly `postgres`.** It matches the ELF against `perf.data`'s mmap
  records *by file name*. A renamed copy gives "no profile for the binary" and a useless `.fdata`.
- **One recording per arm, never shared.** Samples resolve to functions by *address*, so a profile
  taken against a different arm yields near-zero usable data — and `perf2bolt` does not error, it
  writes a thin `.fdata` and `llvm-bolt` then "optimises" almost blind.

**Install** by cloning the *input twin's* prefix and swapping in the BOLTed `bin/postgres`, so every
`lib/*.so` and `share/` file comes from the same compilation as the binary. Cloning a plain `-O3`
prefix instead would pair a PGO+LTO postmaster with `-O3` libraries — two arms mixed in one prefix.

## Gates

A wrong build here does not crash; it produces a plausible binary with the right directory name.
These are the checks that caught real mistakes.

| gate | threshold | why |
|---|---|---|
| `-O3` in `src/Makefile.global` | present | configure substituting its own `-O2` is the most common failure |
| `-fprofile-use` / `-flto` in the **build log** | present | verifies what GCC actually ran with, not what the script believes it passed |
| `.gcda` count | >100 total, >50 under `src/backend` | proves the backends dumped counters |
| `__gcov`/`gcov_` symbols across the **whole prefix** | zero | checking only `bin/postgres` misses `psql`/`pg_ctl`/`pg_dump` |
| pre-existing `.note.bolt_info` | absent | double-BOLTing is a real and confusing mistake |
| `initdb` + `SELECT count(*) FROM generate_series(1,1000)` | passes | LTO plus `--export-dynamic` can drop symbols loadable modules resolve against |
| `.rela.text` on BOLT's input | ≥1 | absent means linked without `-Wl,-q` |
| `.debug_line` on BOLT's input | ≥1 | absent means built without `-g` |
| `.fdata` size | >500 KB | a few hundred KB means the profile did not match this ELF; good runs are tens of MB |
| functions with a profile | >200 | below that the layout was rewritten essentially blind |

---

## Scripts

| script | runs on | does |
|---|---|---|
| `pg-build.sh` | database host | builds one arm from a pristine `git archive` tree; holds every arm's flag set and all build-side gates |
| `pg-train.sh` | load client | drives the PGO training run and verifies the `.gcda` actually landed |
| `pg-profile.sh` | load client | orchestrates a profiling run: start server, apply load, record inside the steady-state window |
| `pg-record.sh` | database host | the `perf record` invocation, one mode for BOLT and one for AutoFDO |
| `pg-bolt.sh` | BOLT host | `perf2bolt` + `llvm-bolt`, with the profile-quality gates |
| `gcc15/pg-build.sh` | database host | gcc 15.2.0 variant of `pg-build.sh`: AutoFDO + LTO profile on the compile line too (see the gcc 15.2.0 section at the end) |

The split across three hosts is not incidental. Amazon Linux 2023 ships no BOLT, so the sampled
binary and its `perf.data` move to a host that has it, and only the rewritten `postgres` comes back.
The load generator is a separate machine from the database under test so that HammerDB's own CPU
cost never competes with the server being measured.

## Scope and honesty notes

- **The five-machine confirmation compares two arms**, `base` and `pgoltob`. The ten-arm lattice that
  chose `pgoltob` in the first place (standalone PGO, PGO+BOLT without LTO, BOLT alone and an AutoFDO
  family) ran on one machine only; its measurements are in [Results](#results) section 1, `pg-build.sh`
  contains every arm's flag set, and `BUILD-OPTIONS.md` records the AutoFDO-specific traps.
- **The gain is established for the PGO+LTO+BOLT combination, not for BOLT in isolation.** In the one
  window where both had two iterations, PGO+LTO+BOLT led PGO+LTO by only 1.31%.
- **Host addresses and credentials have been removed** from the scripts. Private addresses appear as
  `<DUT_PRIVATE_IP>`; set them for your own hosts.
- The training profile was collected on a 64-vCPU cell but the binaries were measured across whole
  machines. Retraining on the full machine is untested and is plausibly upside.

---

# Results

Three measurements, in the order they were made: a ten-arm lattice that chose the methodology, then the
chosen build against `base` on five machine sizes, then the summary.

Workload throughout: HammerDB 4.7 TPROC-C, NOPM, VU 128/256/512/1024, whole machine unpinned, load
generator on a separate host, dataset resident in `shared_buffers`, datadir on tmpfs. Warehouses scale
with the machine at a constant **8 WH per thread**. `base` is `-O3 -march=native -mtune=native`.

## 1. Choosing the methodology — ten arms on one machine

Every combination of profile source (GCC PGO, AutoFDO, none) with LTO and BOLT, built from the same
source tree and measured in the same campaign on the 48xl (192 threads, SNC-3, 1536 WH). `n` is the
number of mirrored iterations behind each arm. Each cell is the arm's NOPM over base's at the same VU
point; the **mean column is the ratio of the two arm means**, not the mean of the four ratios. Base
absolutes for this set are 2,106,234 / 2,323,960 / 2,230,854 / 2,168,559 NOPM.

| arm | build | n | 128 VU | 256 VU | 512 VU | 1024 VU | mean |
|---|---|---:|---:|---:|---:|---:|---:|
| **pgoltob** | **PGO + LTO + BOLT** | 2 | +3.74% | **+10.13%** | +3.51% | +6.45% | **+6.03%** |
| pgolto | PGO + LTO | 2 | +0.31% | +5.88% | +4.56% | **+7.67%** | +4.66% |
| pgo | PGO | 2 | −0.08% | +2.94% | +1.71% | +1.64% | +2.29% |
| afdoltob | AutoFDO + LTO + BOLT | 3 | +1.00% | +3.11% | +1.04% | +2.79% | +2.01% |
| pgob | PGO + BOLT | 2 | +0.05% | +2.85% | +0.05% | +2.41% | +1.37% |
| afdo | AutoFDO | 2 | +1.11% | +1.37% | −0.34% | +0.30% | +0.61% |
| boltonly | BOLT only | 2 | −0.59% | −0.85% | −0.23% | +1.24% | −0.12% |
| afdolto | AutoFDO + LTO | 3 | −1.69% | +0.59% | −2.09% | −0.90% | −1.00% |
| afdob | AutoFDO + BOLT (no LTO) | 2 | −0.25% | **−6.10%** | −4.30% | −1.02% | −3.00% |

What the lattice decided:

- **PGO+LTO+BOLT wins, and the stages compound.** PGO alone is +2.29%, PGO+LTO is +4.66%, and BOLT on
  top of that reaches +6.03%.
- **BOLT on its own does nothing** (−0.12%). It needs the profile-guided, LTO-d binary underneath it to
  have something worth relaying out.
- **PGO+BOLT without LTO (+1.37%) falls well behind PGO+LTO (+4.66%)**, so LTO is not an optional extra
  to add before BOLT — it is where most of BOLT's headroom comes from.
- **The AutoFDO family loses to the PGO family at every position**, and its no-LTO variant is the worst
  arm in the set (−3.00%). AutoFDO provably shaped codegen there — the profile reached the compile line
  for all 1370 files and the function count dropped 22% — yet it scales worst. That is unexplained, and
  the obvious suspect (profile collected on a 64-vCPU cell, measured on 192 threads) is insufficient,
  because the PGO arms share that training cell and scale normally.

**This ranking depends on screening degraded sweeps, and that has to be stated.** The machine re-rolls
memory placement on every restart, and a spoiled sweep depresses all four VU points with 256 VU hit
roughly twice as hard as the rest. Pooling every sweep with nothing screened (base n=3, absolutes
2,064,515 / 2,255,680 / 2,189,721 / 2,149,064) reorders the table completely:

| arm | 128 VU | 256 VU | 512 VU | 1024 VU | mean |
|---|---:|---:|---:|---:|---:|
| pgolto | +2.34% | +9.09% | +6.52% | +8.64% | **+6.72%** |
| pgo | +1.94% | +6.05% | +3.62% | +2.56% | +4.31% |
| pgob | +2.08% | +5.96% | +1.92% | +3.34% | +3.36% |
| afdo | +3.15% | +4.44% | +1.53% | +1.21% | +2.59% |
| boltonly | +1.41% | +2.15% | +1.64% | +2.15% | +1.85% |
| pgoltob | −0.04% | +1.46% | +0.74% | +2.86% | +1.27% |
| afdoltob | +0.19% | +0.52% | −0.28% | −0.15% | +0.07% |
| afdob | +1.77% | −3.25% | −2.50% | −0.13% | −1.09% |
| afdolto | −2.71% | −3.15% | −3.90% | −3.97% | −3.46% |

`pgoltob` drops from first to sixth. Both tables are real; they differ only in which sweeps are treated
as valid. The screened table is the one the selection used, on the grounds that a sweep whose four
points are uniformly depressed is measuring memory placement rather than codegen — but anyone quoting
+6.03% should know that pooling the same campaign unscreened gives +1.27%, and that `pgolto` leads under
the unscreened pooling. What settles the choice is the five-machine confirmation below, which was run as
clean mirrored pairs in one window per machine.

## 2. Final result — `base` vs `pgoltob` on five machine sizes

Two iterations per arm per point, mirrored order, one uninterrupted window per machine.
† marks a reading whose spread against its pair mean flags it as degraded; it is still included.

| box | T | WH | VU | base i1 | base i2 | base mean | pgoltob i1 | pgoltob i2 | pgoltob mean | delta |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 48xl | 192 | 1536 | 128 | 2,104,993 | 2,107,476 | 2,106,235 | 2,183,049 | 2,187,153 | 2,185,101 | +3.74% |
| 48xl | 192 | 1536 | 256 | 2,349,482 | 2,298,439 | 2,323,961 | 2,570,074 | 2,548,576 | 2,559,325 | +10.13% |
| 48xl | 192 | 1536 | 512 | 2,231,451 | 2,230,256 | 2,230,854 | 2,337,366 | 2,280,996 | 2,309,181 | +3.51% |
| 48xl | 192 | 1536 | 1024 | 2,179,969 | 2,157,149 | 2,168,559 | 2,330,585 | 2,286,354 | 2,308,470 | +6.45% |
| **48xl** | | | **mean** | | | **2,207,402** | | | **2,340,519** | **+6.03%** |
| 24xl | 96 | 768 | 128 | 1,955,929 | 2,112,861 | 2,034,395 | 2,297,218 | 2,288,794 | 2,293,006 | +12.71% |
| 24xl | 96 | 768 | 256 | 2,496,389 | 2,687,016 | 2,591,703 | 2,792,136 | 2,759,277 | 2,775,707 | +7.10% |
| 24xl | 96 | 768 | 512 | 2,419,263 | 2,507,800 | 2,463,532 | 2,698,481 | 2,686,148 | 2,692,315 | +9.29% |
| 24xl | 96 | 768 | 1024 | 2,294,620 | 2,352,362 | 2,323,491 | 2,587,570 | 2,585,729 | 2,586,650 | +11.33% |
| **24xl** | | | **mean** | | | **2,353,280** | | | **2,586,919** | **+9.93%** |
| 16xl | 64 | 512 | 128 | 2,136,936 | 2,132,740 | 2,134,838 | 2,226,778 | 2,230,014 | 2,228,396 | +4.38% |
| 16xl | 64 | 512 | 256 | 2,575,840 | 2,578,430 | 2,577,135 | 2,859,658 | 2,901,061 | 2,880,360 | +11.77% |
| 16xl | 64 | 512 | 512 | 1,939,287 † | 2,325,940 | 2,132,614 | 2,306,052 | 2,347,367 | 2,326,710 | +9.10% |
| 16xl | 64 | 512 | 1024 | 1,908,762 | 2,041,153 | 1,974,958 | 2,245,560 | 2,234,220 | 2,239,890 | +13.41% |
| **16xl** | | | **mean** | | | **2,204,886** | | | **2,418,839** | **+9.70%** |
| 12xl | 48 | 384 | 128 | 2,091,252 | 2,072,024 | 2,081,638 | 2,214,343 | 2,225,734 | 2,220,039 | +6.65% |
| 12xl | 48 | 384 | 256 | 2,075,580 | 2,073,458 | 2,074,519 | 2,336,410 | 2,343,626 | 2,340,018 | +12.80% |
| 12xl | 48 | 384 | 512 | 1,880,464 | 1,892,319 | 1,886,392 | 2,095,319 | 2,039,698 | 2,067,509 | +9.60% |
| 12xl | 48 | 384 | 1024 | 1,560,395 † | 1,709,401 | 1,634,898 | 1,935,588 | 1,637,031 † | 1,786,310 | +9.26% |
| **12xl** | | | **mean** | | | **1,919,362** | | | **2,103,469** | **+9.59%** |
| 8xl | 32 | 256 | 128 | 1,623,406 | 1,619,156 | 1,621,281 | 1,850,270 | 1,866,658 | 1,858,464 | +14.63% |
| 8xl | 32 | 256 | 256 | 1,541,978 | 1,533,183 | 1,537,581 | 1,714,700 | 1,717,299 | 1,716,000 | +11.60% |
| 8xl | 32 | 256 | 512 | 1,270,041 | 1,278,281 | 1,274,161 | 1,424,844 † | 1,575,278 | 1,500,061 | +17.73% |
| 8xl | 32 | 256 | 1024 | 1,159,776 | 1,187,406 | 1,173,591 | 1,347,173 | 1,314,672 | 1,330,923 | +13.41% |
| **8xl** | | | **mean** | | | **1,401,653** | | | **1,601,362** | **+14.25%** |

**`pgoltob` won all 20 box × VU cells.** Absolute NOPM is comparable only *within* a box: warehouse
count scales with the machine, and the two smallest boxes had to reduce `shared_buffers` (12xl 100GB,
8xl 64GB) to fit their RAM. Only the within-box ratio travels between machines.

## 3. Summary

| VU | 48xl | 24xl | 16xl | 12xl | 8xl |
|---|---:|---:|---:|---:|---:|
| 128 | +3.74% | +12.71% | +4.38% | +6.65% | +14.63% |
| 256 | +10.13% | +7.10% | +11.77% | +12.80% | +11.60% |
| 512 | +3.51% | +9.29% | +9.10% | +9.60% | +17.73% |
| 1024 | +6.45% | +11.33% | +13.41% | +9.26% | +13.41% |
| **mean** | **+6.03%** | **+9.93%** | **+9.70%** | **+9.59%** | **+14.25%** |
| vs base's best reading | +5.57% | +7.12% | +6.53% | +8.31% | +13.75% |

The last row is the conservative reading: each arm mean against base's *better* iteration at every VU
point, so no weak baseline sweep can inflate it. **Quote +5.5% to +8.5% from the four
standard-configuration boxes.**

Three limits on how far this generalises:

- **The 8xl's +14.25% is the largest number here and the least safe to pool with the rest.** It is the
  only machine carrying two configuration deviations (`shared_buffers=64GB`, `max_wal_size=32GB`, both
  forced by 247 GiB of RAM), and both plausibly favour the optimised build on their own: a smaller pool
  spends proportionally more time in buffer-management code, and a smaller WAL forces more frequent
  checkpoints — exactly the hot branchy paths this pipeline optimises best. "Smaller machine" and
  "smaller configuration" cannot be separated from this data, so it is reported separately above. The
  clean test, re-running the 12xl at the 8xl configuration, has not been run.
- **The 48xl's +6.03% is the softest number in the set, not the firmest.** No single window on that
  machine caught both arms clean, so its base pair and its `pgoltob` pair come from two campaigns. The
  other four legs are each one clean mirrored pair from one window.
- **There is no monotonic trend with core count.** The means run +6.03% (192T) / +9.93% (96T) / +9.70%
  (64T) / +9.59% (48T) — the three smaller machines cluster and the largest is lowest — but the
  conservative row scrambles that ordering entirely (+5.57 / +7.12 / +6.53 / +8.31). The 48xl also
  differs in warehouse count and NUMA topology, so it is not a clean core-count comparison either.

# gcc 15.2.0 build matrix: AutoFDO, AutoFDO + LTO, AutoFDO + LTO + BOLT, PGO, PGO + LTO, PGO + LTO + BOLT

**Status (2026-09-30): in progress.** Done so far: the full toolchain (gcc 15.2.0, AutoFDO
`create_gcov`, `llvm-bolt`/`perf2bolt` 18.1.3, and a HammerDB 4.7 client with the PostgreSQL driver
verified), plus the three profile-free builds (`base`, `prep`, `pgogen`), each of which passes its
gates and answers a smoke query. The HammerDB training, profile recording, profile-guided builds and
BOLT steps below are the plan and have not run yet. No performance numbers are claimed in this section.

This rebuilds the whole six-arm matrix with gcc 15.2.0 on one r8i.metal-48xl (Xeon 6975P-C, 192 vCPU,
3 NUMA nodes), with a separate r8i.16xlarge HammerDB client in the same availability zone. The recipe
is the one documented above; the differences are listed at the end of the section.

## Why: AutoFDO + LTO now applies the profile

The earlier `afdolto` / `afdoltob` arms passed `-fauto-profile` on the link line only, to avoid a
reported gcc 14.2.1 internal compiler error with `-flto` and `-fauto-profile` on one compile line.
On the link line alone the profile is ignored: GCC's AutoFDO pass runs per translation unit, before
LTO streaming. So those arms were effectively plain LTO and plain LTO + BOLT.

Retested on PostgreSQL 18.3 (`REL_18_3`, 62d6c7d3df6) with the earlier sysbench-trained profile,
the profile on **both** the compile and link lines, and `make -k` so every crashing file would be counted:

| compiler | build | internal compiler errors | `.text` bytes | vs plain LTO |
|---|---|---|---|---|
| gcc 14.2.1 | plain LTO (control) | 0 | 8,325,106 | — |
| gcc 14.2.1 | AutoFDO + LTO | 0 | 8,526,994 | +2.4% |
| gcc 14.2.1 | AutoFDO + LTO, `-g -fno-reorder-blocks-and-partition` | 0 | 8,474,034 | +1.8% |
| gcc 15.2.0 | plain LTO (control) | 0 | 8,935,970 | — |
| gcc 15.2.0 | AutoFDO + LTO | 0 | 9,101,522 | +1.9% |
| gcc 15.2.0 | AutoFDO + LTO, `-g -fno-reorder-blocks-and-partition` | 0 | 9,044,914 | +1.2% |

Neither compiler crashed on PostgreSQL, and each AutoFDO + LTO build differs from its plain LTO control,
so the profile is applied. The crash was observed on a C++ code base and does not reproduce here. A
different profile could still trigger it; the build log gate below would show it.

## Common to every build

Every build below is produced by [`scripts/gcc15/pg-build.sh <arm>`](scripts/gcc15/pg-build.sh).

| item | value |
|---|---|
| source | stock PostgreSQL 18.3, tag `REL_18_3` (62d6c7d3df6), exported fresh per build with `git archive` |
| compiler | gcc 15.2.0 built from the GNU release (`--enable-languages=c,c++ --disable-multilib --disable-bootstrap --enable-lto --with-system-zlib`), installed at `/opt/gcc15` |
| LTO archivers | `AR/RANLIB/NM = /opt/gcc15/bin/gcc-{ar,ranlib,nm}` |
| configure | `--prefix=/opt/g15-pg18-<arm> --with-openssl --with-readline` (ICU on, JIT off) |
| make | `make -j192` |
| `COMMON` | `-O3 -march=native -mtune=native` |
| `LTO` | `-flto=96 -ffat-lto-objects` |
| `PGOUSE` | `-fprofile-use -fprofile-correction -fprofile-partial-training -Wno-missing-profile` |
| `AFDO` | `-fauto-profile=pg18-g15-hammerdb.afdo` |
| AutoFDO tools | upstream `google/autofdo`, `cmake -DCMAKE_BUILD_TYPE=Release -DENABLE_TOOL=GCOV`, producing `create_gcov` / `dump_gcov`; `Protobuf_USE_STATIC_LIBS` switched to `FALSE` in `CMakeLists.txt`, because the distribution ships only a shared protobuf |
| BOLT tools | `llvm-bolt` 18.1.3 from tag `llvmorg-18.1.3`: `cmake -G Ninja ../llvm -DLLVM_ENABLE_PROJECTS=bolt -DLLVM_TARGETS_TO_BUILD=X86 -DCMAKE_BUILD_TYPE=Release -DLLVM_ENABLE_ASSERTIONS=OFF`, then `ninja bolt`; `llvm-bolt` and `merge-fdata` copied to `/opt/llvm-bolt-18.1.3/bin`, and `perf2bolt` is a symlink to `llvm-bolt` |
| HammerDB client | HammerDB 4.7 with the PostgreSQL client library (`libpq`), in the same availability zone as the server |

## Step by step

**Step 1. Builds that need no profile** (done)

| build | CFLAGS | LDFLAGS | role | md5 / `.text` bytes |
|---|---|---|---|---|
| `base` | `COMMON` | – | control arm | `f8459d95d7de` / 7,033,986 |
| `prep` | `COMMON -g` | `-Wl,-q` | binary that is profiled for AutoFDO | `c5a1c649e46e` / 7,033,986 |
| `pgogen` | `COMMON -fprofile-generate -fprofile-update=prefer-atomic` | `-fprofile-generate` (+ `make enable_coverage=yes`) | PGO training binary | `dd62742f97e9`, 59,300 gcov symbols |

`prep` has the same `.text` size as `base`, confirming that `-g` and `-Wl,-q` do not change code generation.

**Step 2. PGO training** on `pgogen`

- Server pinned to NUMA node 1 (`32-63,128-159`, memory on node 1): a 64-vCPU training cell.
- HammerDB 4.7 TPROC-C, 1536 warehouses, **64 VU** (the cell's core count), 3 min rampup + 10 min run,
  `allwarehouse true`, `keyandthink false`, stored procedures on.
- Before training, delete the `.gcda` files written by the build's own tools. Stop with `pg_ctl -m fast`;
  an immediate stop skips the exit handlers and loses every counter.

**Step 3. PGO builds**, reusing the trained tree in place

| build | CFLAGS | LDFLAGS | role |
|---|---|---|---|
| `pgo` | `COMMON PGOUSE` | – | **arm: PGO** |
| `pgolto` | `COMMON PGOUSE LTO` | `LTO` | **arm: PGO + LTO** |
| `pgoltoq` | `COMMON PGOUSE LTO -g` | `LTO -Wl,-q` | BOLT input, not benchmarked |

**Step 4. AutoFDO recording**, on `prep` under the step 2 load (6 min of load; recording starts 30 s after rampup)

```
echo 0 > /proc/sys/kernel/nmi_watchdog          # frees a PMU counter; restored afterwards
perf record -e cycles:u -j any,u -c 400009 \
    -C 32-63,128-159 -m 128M --proc-map-timeout 5000 -o perf-afdo.data -- sleep 180
perf inject --build-ids -i perf-afdo.data -o perf-afdo.inj.data
create_gcov --binary=postgres --profile=perf-afdo.inj.data \
    --gcov=pg18-g15-hammerdb.afdo --gcov_version=2
```

gcc 15.2.0 reads version-2 AutoFDO profiles (verified by the retest above).

**Step 5. AutoFDO builds**

| build | CFLAGS | LDFLAGS | role |
|---|---|---|---|
| `afdo` | `COMMON AFDO` | – | **arm: AutoFDO** |
| `afdolto` | `COMMON LTO AFDO` | `LTO AFDO` | **arm: AutoFDO + LTO** (profile now on the compile line too) |
| `afdoltoq` | `COMMON LTO -g -fno-reorder-blocks-and-partition AFDO` | `LTO -Wl,-q AFDO -fno-reorder-blocks-and-partition` | BOLT input, not benchmarked |

The build gate now requires `-fauto-profile` in the compile commands of `afdolto` and `afdoltoq`, not just
on the link line.

**Step 6. BOLT recording**, one per BOLT input and never shared (perf2bolt matches samples by address)

```
perf record -b -z1 --aio=4 -c 100003 -e branches:u \
    -C 32-63,128-159 -m 128M --proc-map-timeout 5000 -o perf-bolt-<arm>.data -- sleep 180
```

Run once against `pgoltoq` and once against `afdoltoq`, each serving the step 2 load.

**Step 7. BOLT rewrite** (llvm-bolt 18.1.3)

```
perf2bolt -p perf-bolt-<arm>.data -o <arm>.fdata ./postgres      # input file must be named "postgres"
llvm-bolt ./postgres -o postgres.bolt -data=<arm>.fdata \
    -reorder-blocks=ext-tsp -reorder-functions=cdsort -split-functions \
    -split-all-cold -split-eh -dyno-stats --update-debug-sections
```

- `pgoltoq` becomes **arm: PGO + LTO + BOLT**, and `afdoltoq` becomes **arm: AutoFDO + LTO + BOLT**.
- Each BOLTed binary goes into a copy of its input's install prefix, so the libraries come from the same compile.
- Gates: `.fdata` > 500 KB, > 200 functions with profile data, `.note.bolt_info` present.

## Differences from the gcc 14.2.1 recipe above

1. gcc 15.2.0 instead of gcc 14.2.1.
2. AutoFDO + LTO puts the profile on the compile line as well as the link line, which is what applies it.
3. New HammerDB-trained profiles are recorded from these gcc 15 builds; PGO training and the AutoFDO
   recording use the same load.

One asymmetry is kept from the recipe above: `afdoltoq` disables hot/cold splitting
(`-fno-reorder-blocks-and-partition`) but `pgoltoq` does not, so the results stay comparable with the
earlier campaign.
