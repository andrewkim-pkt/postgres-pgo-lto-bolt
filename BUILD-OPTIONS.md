# Build options: PGO + LTO + BOLT for PostgreSQL 18.3

Reference for the `pgoltob` arm (PGO + LTO + BOLT) and the intermediate builds it depends on.
Every option below is the one actually used to produce the measured binaries; see
[RESULTS.md](RESULTS.md) for what they bought.

## Toolchain and source

| item | value |
|---|---|
| compiler | GCC 14.2.1 (`gcc14-gcc` on Amazon Linux 2023), on the database host |
| LTO archivers | `AR=gcc14-gcc-ar RANLIB=gcc14-gcc-ranlib NM=gcc14-gcc-nm` |
| BOLT | `perf2bolt` / `llvm-bolt`, run on a separate Ubuntu host |
| source | stock PostgreSQL 18.3 (`62d6c7d3df6`, "Stamp 18.3."), `NUM_XLOGINSERT_LOCKS` at its stock 8 |
| tree export | `git archive <rev> \| tar -x` into a fresh directory, one per arm |
| configure | `./configure --prefix=$PREFIX --with-openssl --with-readline CC=… CFLAGS=… LDFLAGS=…` |
| parallelism | `make -j192`, `-flto=96` |

Two toolchain notes that are easy to get wrong:

- **`gcc-ar`/`gcc-ranlib`/`gcc-nm` must come from the same GCC as the compiler** for any LTO arm.
  A mismatch loads the wrong plugin for the IR inside `libpgcommon.a` / `libpgport.a`, and the link
  either fails outright or silently drops cross-module inlining — which looks like "LTO did nothing".
- **JIT stays off** (no `--with-llvm`). JIT-generated code is untouched by BOLT, and its anonymous
  runtime code pollutes the LBR recordings that feed `perf2bolt`.

The configure line is byte-identical for every arm. `CFLAGS`/`LDFLAGS` are the only difference,
so the measurement is of the optimisation options and not of the build configuration.

## Common flags

```
COMMON = -O3 -march=native -mtune=native
LTO    = -flto=96 -ffat-lto-objects
PGOUSE = -fprofile-use -fprofile-correction -fprofile-partial-training -Wno-missing-profile
```

`-ffat-lto-objects` is required rather than merely conservative: PostgreSQL's build runs objects
through `ar`/`ranlib` *and* executes generated tools during the build, so each `.o` needs to carry
both the IR and real machine code or one of those two paths breaks.

Within `PGOUSE`:

- `-fprofile-use` with **no `=path`** — GCC then looks for each `.gcda` beside its own object file,
  which is why the PGO arms must reuse the instrumented tree in place.
- `-fprofile-correction` is **mandatory, not optional**. Multi-process counter merging leaves
  inconsistent counts and GCC hard-errors without it.
- `-fprofile-partial-training` keeps never-trained functions at `-O3` instead of size-optimising
  them. This matters because a TPROC-C workload never touches most of PostgreSQL.

## The four steps to `pgoltob`

`pgoltob` is a chain of three GCC builds plus a BOLT rewrite. Note that the benchmarked
`pgolto` binary is **not** BOLT's input: `pgoltoq` is, and it differs from `pgolto` by `-g` and
`-Wl,-q`.

### 1. Instrumented build

```
CFLAGS  = -O3 -march=native -mtune=native -fprofile-generate -fprofile-update=prefer-atomic
LDFLAGS = -fprofile-generate
make     enable_coverage=yes
```

`-fprofile-update=prefer-atomic` keeps the counters sane when several hundred backends touch the
same `.gcda` — PostgreSQL forks one backend per connection and the training run has hundreds.

`enable_coverage=yes` is a **make variable, not a compiler flag**, and it adds no flags. It exists
only to skip `src/interfaces/libpq/Makefile`'s `libpq-refs-stamp` rule, which fails the build if
`libpq.so` references anything calling `exit()`. `-fprofile-generate` links gcov's at-exit `.gcda`
dumper, so it does. PostgreSQL's own comment names this case. The same variable is needed again at
`make install`, because install re-evaluates the `all` prerequisites.

Side effect to know about: `enable_coverage=yes` hooks `clean-coverage` (`rm -f *.gcda`) into
`make clean`, so **this tree must never be `make clean`ed** between training and the
`-fprofile-use` builds.

### 2. Training run

```
VU        = 64   (= core count of the training cell, NOT the optimised binary's peak)
warehouses= 1536
rampup    = 3 min
duration  = 10 min
```

Three things this step gets wrong if you are not careful:

- **VU is set to core count, deliberately.** Training at the optimised binary's peak VU piles
  samples into lock-wait paths (`ut_delay` and friends) instead of real work, which cost BOLT half
  its headroom (−2.5%) in an earlier campaign.
- **The instrumented build already wrote `.gcda` into the tree** — every instrumented build-time
  tool PostgreSQL compiles and then runs dumps counters at the same object paths the backends will
  use. Those are build-tool counters, not training data. Delete them before training starts.
- **Shutdown must be graceful.** `pg_ctl -m immediate` sends SIGQUIT, which skips exit handlers,
  so no backend dumps its counters and **the entire training run is lost**. Every one of the several
  hundred `.gcda` writers has to come down cleanly.

### 3. Optimised build with LTO, plus BOLT's retained relocations

```
CFLAGS  = -O3 -march=native -mtune=native \
          -fprofile-use -fprofile-correction -fprofile-partial-training -Wno-missing-profile \
          -flto=96 -ffat-lto-objects -g
LDFLAGS = -flto=96 -ffat-lto-objects -Wl,-q
```

`-g` gives BOLT its `.debug_line`; `-Wl,-q` retains relocations so `.rela.text` survives the link.
`llvm-bolt` rejects the binary without the latter. Neither changes codegen.

This build **reuses the instrumented tree in place**, deleting build products while keeping
`*.gcda` and `*.gcno`. Two deletions are load-bearing and neither is obvious:

- **`objfiles.txt` must go.** It is PostgreSQL's per-directory build stamp (`all: objfiles.txt` in
  `src/backend/common.mk`) and it defeats a plain object delete: with the stamp present a backend
  subdirectory reports "Nothing to be done for `all`" and compiles nothing, then the top-level link
  reads the object list back out of the stamp and dies with
  `cannot find access/brin/brin_minmax_multi.o`. Measured on `src/backend/access/brin`: `make -n`
  emits 10 compile actions without the stamp and 0 with it.
- **Linked programs must go too**, not just `src/backend/postgres`. Without that, `make` recompiles
  objects but never relinks, so instrumented tools survive from the previous build and
  `make install` copies them into the new prefix. Observed: 36 of the tree's 39 executables were
  stale that way (`psql` with 2875 gcov symbols, `pg_ctl` 542, `pg_dump` 2650) while
  `bin/postgres` itself was clean. That is not cosmetic — an instrumented `psql` or `pg_ctl` writes
  `.gcda` *back into the training tree* when run, mutating the profile after training. Match on ELF
  magic rather than a name list; the stale set spans `src/bin`, `src/interfaces/ecpg`,
  `src/timezone/zic` and `src/test`.

### 4. BOLT

**Recording**, on the database host, against the `-g -Wl,-q` twin while it serves load:

```
perf record -b -z1 --aio=4 -c 100003 -e branches:u \
    -C <cpu-list> -m 128M --proc-map-timeout 5000 -o perf.data -- sleep 180
```

Branch-driven, not cycles-driven: `perf2bolt` only cares about taken-branch source/target pairs.
(By contrast the AutoFDO arms record `-e cycles:u -j any,u -c 400009`, because `create_gcov`'s edge
inference wants a cycles-driven sample with a branch stack.) `-z1` compresses, because an
uncompressed 180 s branch record on 64 vCPU is tens of GB; `--aio=4` keeps the writer off the
profiled CPUs. `nmi_watchdog` is disabled for the window and restored afterwards.

Recording window: 6 min of load, 30 s settle after rampup, 180 s recorded — the record must finish
inside the load window, or you capture teardown instead of steady state.

**Conversion and rewrite**, on a host that has BOLT:

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

Two `perf2bolt` constraints that fail quietly rather than loudly:

- **The input must be named exactly `postgres`.** `perf2bolt` matches the ELF against `perf.data`'s
  mmap records *by file name*. Feed it a renamed copy and you get "no profile for the binary" and a
  useless `.fdata`.
- **One recording per arm, no sharing.** `perf2bolt` resolves samples to functions by *address* in
  the input binary. Different arms have different layouts, so a profile taken against one produces
  near-zero usable data for another — and `perf2bolt` does not error out, it writes a thin `.fdata`
  and `llvm-bolt` then "optimises" with almost no profile.

**Deliberately excluded:** `--icf`, `--icp=all`, `--hugify`. That richer set measured a
wash-to-loss on this workload.

**Installation** clones the *input twin's* prefix and swaps in the BOLTed `bin/postgres`, so every
`lib/*.so` and `share/` file comes from the same compilation as the binary. Cloning a plain `-O3`
prefix instead would pair a PGO+LTO postmaster with `-O3` libraries — two arms mixed in one prefix.

## Gates

A wrong build here does not crash; it produces a plausible binary with the right directory name.
These are the checks that caught real mistakes.

**Build side**

| gate | why |
|---|---|
| `-O3` present in `src/Makefile.global` | the most common failure is configure substituting its own `-O2`, leaving an `-O2` build with the right name |
| `-fprofile-use` and `-flto` present in the **build log** | verifies the flags GCC actually ran with, not what the script believes it passed |
| `.gcda` count > 100 overall, > 50 under `src/backend` | proves the backends dumped counters, i.e. training actually landed |
| zero `__gcov`/`gcov_` symbols across the **whole prefix** | checking only `bin/postgres` misses instrumented `psql`/`pg_ctl`/`pg_dump` |
| no pre-existing `.note.bolt_info` | double-BOLTing a binary is a real and confusing mistake |
| `initdb` + `SELECT count(*) FROM generate_series(1,1000)` | LTO plus `--export-dynamic` can drop symbols that loadable modules resolve against; a binary that builds but cannot answer a query is worse than a build failure |

**BOLT side**

| gate | threshold | why |
|---|---|---|
| `.rela.text` sections on the input | ≥ 1 | absent means the build was linked without `-Wl,-q` |
| `.debug_line` sections on the input | ≥ 1 | absent means the build lacked `-g` |
| `.fdata` size | > 500 KB | a few hundred KB means the profile did not match this ELF; good runs are tens of MB |
| functions with a non-empty execution profile | > 200 | below that the layout was rewritten essentially blind |

## Related arms and one deliberate asymmetry

The wider lattice also built AutoFDO variants. Their BOLT input twins add
`-fno-reorder-blocks-and-partition`, because `-fauto-profile` turns hot/cold splitting on and BOLT
handles pre-split functions badly. **The PGO input twin does not disable splitting** — it is left on
so the arm stays comparable with an earlier campaign that measured it that way. If you are starting
fresh rather than matching prior numbers, disabling it on the PGO side too is worth testing.

One AutoFDO-specific trap, recorded here because it shapes what is comparable: GCC 14.2.1 ICEs
(`einline` / `pp_format`) when `-flto` and `-fauto-profile` are both on the compile line. Putting
the profile only on the *link* line avoids the ICE, but the flag then never reaches a compile
command, so it cannot be audited from the build log the way the other arms can.
