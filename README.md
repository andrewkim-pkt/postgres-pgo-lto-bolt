# postgres-pgo-lto-bolt

Build recipe and measurements for PGO + LTO + BOLT applied to **stock PostgreSQL 18.3**, benchmarked
with HammerDB 4.7 TPROC-C on Xeon 6975P-C (Granite Rapids) across five machine sizes.

**Result: +5.5% to +8.5% NOPM** over a plain `-O3 -march=native` build, measured conservatively
against the better of two baseline iterations. The optimised build won every one of the 20
box × virtual-user cells tested. Full tables and caveats in [RESULTS.md](RESULTS.md).

## Contents

| file | what it is |
|---|---|
| [BUILD-OPTIONS.md](BUILD-OPTIONS.md) | the same pipeline as below, plus the failure modes behind each flag and the gates that catch a silently-wrong build |
| [RESULTS.md](RESULTS.md) | NOPM for both arms at every virtual-user count on every box, plus what the data does and does not support |
| [scripts/](scripts/) | the scripts that produced it |

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

- **Two arms are compared here**, `base` and `pgoltob`. The wider campaign built a ten-arm lattice
  (standalone PGO, PGO+BOLT without LTO, and an AutoFDO family); `pg-build.sh` still contains all of
  those flag sets, and `BUILD-OPTIONS.md` records the AutoFDO-specific traps, but their measurements
  are not published here.
- **The gain is established for the PGO+LTO+BOLT combination, not for BOLT in isolation.** In the one
  window where both had two iterations, PGO+LTO+BOLT led PGO+LTO by only 1.31%.
- **Host addresses and credentials have been removed** from the scripts. Private addresses appear as
  `<DUT_PRIVATE_IP>`; set them for your own hosts.
- The training profile was collected on a 64-vCPU cell but the binaries were measured across whole
  machines. Retraining on the full machine is untested and is plausibly upside.
