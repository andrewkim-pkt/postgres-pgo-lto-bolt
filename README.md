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

## Contents

| file | what it is |
|---|---|
| [BUILD-OPTIONS.md](BUILD-OPTIONS.md) | the same pipeline as below, plus the failure modes behind each flag and the gates that catch a silently-wrong build |
| [RESULTS.md](RESULTS.md) | NOPM for both arms at every virtual-user count on every box, plus what the data does and does not support |
| [scripts/](scripts/) | the scripts that produced it |
| [binaries/](binaries/) | the shipped `pgoltob` build itself, as an install prefix — the same tree that produced the numbers below |

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
