# postgres-pgo-lto-bolt

Build recipe and measurements for PGO + LTO + BOLT applied to **stock PostgreSQL 18.3**, benchmarked
with HammerDB 4.7 TPROC-C on Xeon 6975P-C (Granite Rapids) across five machine sizes.

**Result: +5.5% to +8.5% NOPM** over a plain `-O3 -march=native` build, measured conservatively
against the better of two baseline iterations. The optimised build won every one of the 20
box × virtual-user cells tested. Full tables and caveats in [RESULTS.md](RESULTS.md).

## Contents

| file | what it is |
|---|---|
| [BUILD-OPTIONS.md](BUILD-OPTIONS.md) | the complete recipe: compiler flags, training parameters, `perf record` invocation, `llvm-bolt` flags, and the gates that catch a silently-wrong build |
| [RESULTS.md](RESULTS.md) | NOPM for both arms at every virtual-user count on every box, plus what the data does and does not support |
| [scripts/](scripts/) | the scripts that produced it |

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
