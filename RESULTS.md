# Results: PGO+LTO+BOLT vs `-O3 -march=native` on PostgreSQL 18.3

HammerDB 4.7 TPROC-C, NOPM. Two arms only:

- **base** — `-O3 -march=native -mtune=native`
- **pgoltob** — the same, plus PGO, plus LTO, plus BOLT (see [BUILD-OPTIONS.md](BUILD-OPTIONS.md))

Both arms are the same source revision (stock PostgreSQL 18.3) and the same `configure` line. Runs
are `n=2` mirrored — the second iteration reverses arm order so any drift within the window cancels
rather than accumulating in one arm's favour.

## Headline

| box | threads | warehouses | mean gain | vs base's best reading |
|---|---|---|---|---|
| 48xl | 192 | 1536 | +6.03% | +5.57% |
| 24xl | 96 | 768 | +9.93% | +7.12% |
| 16xl | 64 | 512 | +9.70% | +6.53% |
| 12xl | 48 | 384 | +9.59% | +8.31% |
| 8xl | 32 | 256 | +14.25% | +13.75% |

**The defensible number is +5.5% to +8.5%**, taken from the "vs base's best reading" column on the
four boxes that share one configuration. That column compares `pgoltob`'s mean against the *best* of
base's two iterations at each VU point, so a single bad base sweep cannot inflate the result.

**The 8xl's +13.75% is reported separately and should not be pooled into that range.** It is the only
box with configuration deviations (`shared_buffers=64GB`, `max_wal_size=32GB`, both forced by having
only 247 GiB of RAM), and both deviations plausibly favour `pgoltob` on their own: a smaller buffer
pool puts proportionally more time in buffer-management code, and a smaller WAL forces more frequent
checkpoints. Both are exactly the hot, branchy code that PGO+LTO+BOLT optimises best. "Smaller box"
and "smaller configuration" cannot be separated from this data.

`pgoltob` won all 20 box × VU cells.

## Per-VU detail

Warehouse count scales with the box at a constant 8 warehouses per thread. `spread` is
`|i1 − i2| / mean of the pair`.

### 48xl — 192 threads, SNC-3, 1536 WH
| VU | base i1 | base i2 | base | pgoltob i1 | pgoltob i2 | pgoltob | delta | spread b/p |
|---|---|---|---|---|---|---|---|---|
| 128 | 2,104,993 | 2,107,476 | 2,106,235 | 2,183,049 | 2,187,153 | 2,185,101 | +3.74% | 0.12% / 0.19% |
| 256 | 2,349,482 | 2,298,439 | 2,323,961 | 2,570,074 | 2,548,576 | 2,559,325 | +10.13% | 2.20% / 0.84% |
| 512 | 2,231,451 | 2,230,256 | 2,230,854 | 2,337,366 | 2,280,996 | 2,309,181 | +3.51% | 0.05% / 2.44% |
| 1024 | 2,179,969 | 2,157,149 | 2,168,559 | 2,330,585 | 2,286,354 | 2,308,470 | +6.45% | 1.05% / 1.92% |
| **mean** | | | **2,207,402** | | | **2,340,519** | **+6.03%** | |

### 24xl — 96 threads, 2 NUMA nodes, 768 WH
| VU | base i1 | base i2 | base | pgoltob i1 | pgoltob i2 | pgoltob | delta | spread b/p |
|---|---|---|---|---|---|---|---|---|
| 128 | 1,955,929 | 2,112,861 | 2,034,395 | 2,297,218 | 2,288,794 | 2,293,006 | +12.71% | 7.71% / 0.37% |
| 256 | 2,496,389 | 2,687,016 | 2,591,703 | 2,792,136 | 2,759,277 | 2,775,707 | +7.10% | 7.36% / 1.18% |
| 512 | 2,419,263 | 2,507,800 | 2,463,532 | 2,698,481 | 2,686,148 | 2,692,315 | +9.29% | 3.59% / 0.46% |
| 1024 | 2,294,620 | 2,352,362 | 2,323,491 | 2,587,570 | 2,585,729 | 2,586,650 | +11.33% | 2.49% / 0.07% |
| **mean** | | | **2,353,280** | | | **2,586,919** | **+9.93%** | |

### 16xl — 64 threads, 1 NUMA node, 512 WH
| VU | base i1 | base i2 | base | pgoltob i1 | pgoltob i2 | pgoltob | delta | spread b/p |
|---|---|---|---|---|---|---|---|---|
| 128 | 2,136,936 | 2,132,740 | 2,134,838 | 2,226,778 | 2,230,014 | 2,228,396 | +4.38% | 0.20% / 0.15% |
| 256 | 2,575,840 | 2,578,430 | 2,577,135 | 2,859,658 | 2,901,061 | 2,880,360 | +11.77% | 0.10% / 1.44% |
| 512 | 1,939,287 | 2,325,940 | 2,132,614 | 2,306,052 | 2,347,367 | 2,326,710 | +9.10% | **18.13%** / 1.78% |
| 1024 | 1,908,762 | 2,041,153 | 1,974,958 | 2,245,560 | 2,234,220 | 2,239,890 | +13.41% | 6.70% / 0.51% |
| **mean** | | | **2,204,886** | | | **2,418,839** | **+9.70%** | |

### 12xl — 48 threads, 1 NUMA node, 371 GiB, 384 WH, `shared_buffers=100GB`
| VU | base i1 | base i2 | base | pgoltob i1 | pgoltob i2 | pgoltob | delta | spread b/p |
|---|---|---|---|---|---|---|---|---|
| 128 | 2,091,252 | 2,072,024 | 2,081,638 | 2,214,343 | 2,225,734 | 2,220,039 | +6.65% | 0.92% / 0.51% |
| 256 | 2,075,580 | 2,073,458 | 2,074,519 | 2,336,410 | 2,343,626 | 2,340,018 | +12.80% | 0.10% / 0.31% |
| 512 | 1,880,464 | 1,892,319 | 1,886,392 | 2,095,319 | 2,039,698 | 2,067,509 | +9.60% | 0.63% / 2.69% |
| 1024 | 1,560,395 | 1,709,401 | 1,634,898 | 1,935,588 | 1,637,031 | 1,786,310 | +9.26% | 9.11% / **16.71%** |
| **mean** | | | **1,919,362** | | | **2,103,469** | **+9.59%** | |

### 8xl — 32 threads, 1 NUMA node, 247 GiB, 256 WH, `shared_buffers=64GB` + `max_wal_size=32GB`
| VU | base i1 | base i2 | base | pgoltob i1 | pgoltob i2 | pgoltob | delta | spread b/p |
|---|---|---|---|---|---|---|---|---|
| 128 | 1,623,406 | 1,619,156 | 1,621,281 | 1,850,270 | 1,866,658 | 1,858,464 | +14.63% | 0.26% / 0.88% |
| 256 | 1,541,978 | 1,533,183 | 1,537,581 | 1,714,700 | 1,717,299 | 1,716,000 | +11.60% | 0.57% / 0.15% |
| 512 | 1,270,041 | 1,278,281 | 1,274,161 | 1,424,844 | 1,575,278 | 1,500,061 | +17.73% | 0.65% / **10.03%** |
| 1024 | 1,159,776 | 1,187,406 | 1,173,591 | 1,347,173 | 1,314,672 | 1,330,923 | +13.41% | 2.35% / 2.44% |
| **mean** | | | **1,401,653** | | | **1,601,362** | **+14.25%** | |

## How to read this, and what not to claim

**Absolute NOPM is not comparable between boxes.** Warehouse count scales with the box, and two
boxes had to change `shared_buffers`. Only the within-box ratio means anything.

**There is no established trend with core count.** On both-iteration means the four
standard-configuration boxes read +6.03% (192T) / +9.93% (96T) / +9.70% (64T) / +9.59% (48T), which
looks like "smaller box wins more" until you notice the conservative column scrambles the ordering
entirely (+5.57 / +7.12 / +6.53 / +8.31). The 48xl also differs in warehouse count and NUMA topology.
The 8xl at +14.25% appears to complete the story, which is precisely why its configuration confound
matters — it is the one box whose configuration also changed.

**The 48xl leg is the softest number here, not the firmest.** It is the only leg that is *not* a
single-window head-to-head: its base pair and its `pgoltob` pair come from two different campaigns,
because no single window on that box ever measured both arms cleanly. Four sweeps were screened out
as degraded (one base iteration in one campaign, both `pgoltob` iterations in the other). The other
four legs each come from one uninterrupted mirrored campaign and need no such screening.

**Reproducibility: a tendency, not a rule.** On the three larger boxes `pgoltob`'s iteration spread
never exceeded 2.5% at any VU point while base reached 8.0% and 18.1%, which is a real argument for
shipping the optimised build. But both small boxes reversed it at one point each — 12xl at 1024 VU
(`pgoltob` 16.71% vs base 9.11%) and 8xl at 512 VU (`pgoltob` 10.03% vs base 0.65%) — and on the 8xl
base was the tighter arm at every single point. Whatever drives this variance, PGO+LTO+BOLT is not
immune to it.

**Small boxes saturate before the bottom of the VU range.** The 12xl's base arm peaks at 128 VU and
falls monotonically, and on the 8xl *both* arms do. Those curves never capture the actual peak; a
re-run of the smaller boxes should add 32 and 64 VU points. A monotonically falling curve on a small
box is expected, not a sign of a bad sweep.

## Open item

The 8xl's configuration confound is cheap to resolve and has not been run: rebuild the 12xl leg with
the 8xl's configuration (`shared_buffers=64GB`, `max_wal_size=32GB`) and re-measure. If the 12xl
moves from +9.59% toward +14%, the effect is configuration. If it stays near +9.6%, it is genuinely
core count.
