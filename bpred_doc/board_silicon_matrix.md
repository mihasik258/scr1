# SCR1 Branch Predictor — Silicon Board Matrix (stock vs predictor)

Nexys A7-100T (xc7a100t), CPU_CLK 30 MHz, **rv32im** binaries (no compressed).
Predictor-only A/B: same core, predictor disabled (**stock / No-BPU**) vs the full
predictor (early BTB 256 + BTFN + BHT 1024×2b + RAS 4, fetch-side gating).
Numbers are the on-board RTC-tick counts reported by each test (lower = faster).

The predictor bitstream is the **queue-4 + DDR-fix** build; on silicon the queue-2
build measured the same on these tests (memory latency dominates queue depth), so a
single predictor column is used.

## Matrix

| Test | Memory | Opt | Stock (No-BPU) | Predictor | Δ (predictor-only) |
|---|---|---|---|---|---|
| Dhrystone | TCM | O2      | 7 669       | 7 286       | **−4.99 %** |
| Dhrystone | TCM | O3+LTO  | 5 303       | 5 053       | **−4.71 %** |
| Dhrystone | DDR | O2      | 220 665     | 203 379     | **−7.83 %** |
| Dhrystone | DDR | O3+LTO  | 113 360     | 107 924     | **−4.80 %** |
| CoreMark  | TCM | O2      | 16 933 768  | 14 675 279  | **−13.34 %** |
| CoreMark  | TCM | O3+LTO  | 15 539 970  | *(did not fit)* | — |
| CoreMark  | DDR | O2      | 15 651 816  | 13 969 357  | **−10.75 %** |
| CoreMark  | DDR | O3+LTO  | 14 115 912  | 12 878 629  | **−8.77 %** |

## Reading the results

- **Headline: CoreMark O2 / TCM = −13.3 % predictor-only on silicon** (rv32im),
  consistent with the −14.3 % A/B recorded for the pred-q4 bitstream.
- **TCM > DDR gain** (CoreMark 13.3 % vs 10.8 %): DDR2 has no cache, so memory
  latency dominates and dilutes the predictor's benefit — the frontend stalls on
  memory, not on prediction.
- **O2 > O3+LTO gain** (CoreMark DDR 10.8 % vs 8.8 %; Dhrystone DDR 7.8 % vs 4.8 %):
  `-O3 -flto` already straightens and reduces branches in software, leaving less for
  the hardware predictor to recover.
- **Dhrystone < CoreMark gain**: fewer, more predictable branches.

## Caveats

- **CoreMark TCM vs DDR totals are not cross-comparable.** Dhrystone scales as
  expected (DDR ~21–29× slower than TCM), but the raw CoreMark totals are similar
  across TCM/DDR (DDR slightly lower) — impossible at equal iteration count, so the
  CoreMark TCM and DDR runs used **different iteration counts**. The **per-cell
  stock↔predictor Δ is still valid** (same test, same memory, same iterations); only
  the TCM-vs-DDR magnitude comparison is not.
- `CoreMark O3+LTO / TCM` predictor run did not fit in TCM (marked n/a).
- rv32im (no C): the predictor's silicon gain is larger than the rv32imc verilator
  figures in [optimization_study.md](optimization_study.md), because without
  compressed instructions every branch is word-aligned and the RVC steer wall
  disappears — the frontend-addressable bubble is taken by the ordinary early steer.
