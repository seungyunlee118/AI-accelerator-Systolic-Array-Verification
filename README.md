# SA-GEMM: Systolic-Array INT8 GEMM Accelerator Verification

Verification of an INT8 matrix-multiply accelerator: AXI4-Lite CSRs, an AXI4 DMA master with up
to 4 outstanding reads returning **out of order and interleaved**, an N×N output-stationary PE
array (N = 4 and 8), and a ReLU/requantization output stage. UVM on Cadence Xcelium, formal
proofs with SymbiYosys, Python regression, coverage and mutation tooling.

## Results

| | |
|---|---|
| UVM tests | 17 (4 CSR block-level, 13 full-chip), every test in the [verification plan](docs/vplan.md) |
| Regression | 17 tests x 20 seeds, full-chip tests on both 4x4 and 8x8 arrays: **600/600 pass** |
| Functional coverage | **100%** of 386 bins (CG-01..09), no waivers; closed from 98.0% ([closure log](docs/vplan.md#61-closure-log)) |
| Testbench strength | **16/16** injected RTL bugs caught, on both array sizes ([`sim/mutate.py`](sim/mutate.py)) |
| Formal: CSR block | proven by k-induction; 10/10 bug mutants killed, 1 safe change proven |
| Formal: DMA read engine | proven by k-induction **against any AXI4 response order** in ~12 s; 9/9 bug mutants killed by spec properties alone, 2 safe changes proven |
| Spec issues found | 6, answered by the designer and folded into the spec (vplan §9; Q6 led to spec v0.4) |
| RTL bugs found | 0 (see [bug log](docs/bug_log.md) for why that number is credible) |

## Roles
- **Verification** (verification plan, UVM environment, formal, coverage, regression and
  mutation tooling): Seungyun Lee
- **DUT RTL:** written with an AI assistant from [`docs/spec.md`](docs/spec.md), then treated as a
  third-party design under test.

## Architecture
<p align="center">
  <img src="docs/sa_gemm_block_diagram.svg" alt="SA-GEMM DUT block diagram" width="680">
</p>

1. The CPU (the UVM AXI4-Lite agent in simulation) programs the CSR block and writes `CTRL.START`.
2. The controller has the DMA engine fetch A and B from external memory over AXI4
   (up to 4 outstanding read bursts, out-of-order / interleaved responses).
3. The N×N output-stationary systolic array computes each output tile from the A/B buffers.
4. The output stage applies ReLU and optional INT8 requantization; the DMA engine writes C back.
5. On completion or error the CSR block raises `irq`.

## Verification approach
- **Plan first.** [`docs/vplan.md`](docs/vplan.md) maps every spec clause to a feature, bug
  hypotheses, stimulus, checker (CHK-01..12) and coverage (CG-01..09). Korean translations of the
  spec and plan are in `docs/ko/`.
- **UVM environment** (`tb/`):
  - CPU side: AXI4-Lite agent driving a RAL model generated from SystemRDL (PeakRDL), with an
    explicit predictor.
  - Memory side: a reactive AXI4 memory agent with latency, back-pressure on every channel,
    out-of-order and beat-interleaved returns, and error injection.
  - Checking: an independent SV golden model and a job scoreboard (every C byte, a sentinel
    around C, write containment), a DMA checker (read windows, no new burst after an error, BUSY
    timing), and AXI4 / DMA-rule SVA.
- **Automation** (`sim/`):
  - `regress.py` compiles once and runs the snapshot in parallel, writing a summary and JUnit XML.
  - `covmerge.py` merges functional coverage without IMC; each run self-checks its counts against
    the covergroups.
  - `mutate.py` injects RTL bugs and checks that their tests fail.
- **Formal** (`formal/`): SymbiYosys k-induction proofs of the CSR block and the DMA read engine,
  each with covers (no vacuous proof) and its own mutation check.

## What verification found
- **Spec gaps** (vplan §9, Q1–Q6): e.g. BUSY/CYCLES on a configuration error, DONE vs ERR,
  overlapping strides, and the minimum reset pulse (found when a sub-cycle reset desynchronized the
  memory from the DUT; now spec v0.4 §9).
- **Testbench weaknesses**, found by measuring the testbench rather than the DUT:
  - A mutant clamping at `r > 128` survived because random data never produced exactly 128. A
    coverage bin and directed stimulus for the exact saturation edges closed it.
  - Seven coverage holes were triaged into stimulus gaps, impossible bins and 8×8-only bins.
- **Tool behaviour** worth knowing:
  - Xcelium does not sample covergroups without `-cov_cgsample`.
  - `uvm_component::check()` is a deprecated hook that UVM calls by itself.
  - Yosys turns a constant `case` into a ROM, whose contents k-induction treats as free state.
  - A symbolic `row × stride` multiplication made every SMT solver time out; the shadow model now
    builds it by addition.

## Layout
| Path | Contents |
|---|---|
| `docs/spec.md`, `docs/vplan.md` | Design specification (DUT contract), verification plan |
| `docs/ko/` | Korean translations (the English files are authoritative) |
| `docs/bug_log.md` | RTL bugs found by verification, and the evidence behind the result |
| `rtl/` | DUT RTL |
| `ral/` | SystemRDL register map and the PeakRDL generator script |
| `tb/` | UVM environment: agents (`axil/`, `axi/`), env, coverage (`cov/`), tests, smoke tests |
| `sim/` | Xcelium run directory: Makefile, regression, coverage merge, mutation (outputs git-ignored) |
| `formal/` | SymbiYosys proofs: properties, `.sby` scripts, mutation checks |
| `sync.sh` | Copies the repo to the Xcelium server |

## Running
Code is edited on a laptop and simulated on a Linux server with Xcelium.

```bash
./sync.sh                                   # laptop -> server (ssh alias "msd10")
ssh msd10                                   # or use the server's own terminal
cd ~/AI-accelerator-Systolic-Array-Verification/sim
```

One test (inside `sim/`):
```bash
make                                        # csr_reset_test, seed 1 (CSR block-level testbench)
make TB=top TEST=gemm_rand_test SEED=3      # full-chip, 4x4 array
make TB=top8 TEST=gemm_edge_test            # full-chip, 8x8 array
make TB=top TEST=err_bus_test WAVE=1        # record waves.shm; `make view` opens SimVision
```

Regression, coverage and mutation (inside `sim/`):
```bash
python3 regress.py                          # every test, seeds 1..4, both array sizes, coverage merged
python3 regress.py --seeds 20 -j 14         # sign-off depth (600 runs)
python3 regress.py -t err_bus_test --seed-list 7 42 --array 8
python3 mutate.py                           # inject each bug; its target test must fail
python3 mutate.py --array 8                 # the same on the 8x8 build
```

Formal (on the laptop, open-source [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build)):
```bash
source ~/oss-cad-suite/environment
cd formal/csr    && sby -f sa_csr.sby && python3 mutants.py
cd ../dma_rd     && sby -f sa_dma_rd.sby prove cover && python3 mutants.py
gtkwave ../csr/sa_csr_cover/engine_0/trace4.vcd ../csr/csr.gtkw 2>/dev/null   # a cover trace
```

Designer smoke tests (inside `sim/`), e.g.:
```bash
xrun -64bit -sv ../rtl/sa_csr.sv ../tb/smoke/tb_sa_csr.sv
```

Code coverage can be collected with `make CODECOV=1`, but reading it needs Cadence IMC, which the
lab server does not have (open tool item in the vplan).

## History
| Week | Work |
|---|---|
| 1–2 | Spec v0.1–v0.3, verification plan, DUT RTL and smoke tests, SystemRDL/RAL, AXI4-Lite agent, CSR tests |
| 3 | Full-chip UVM environment (memory agent, golden model, scoreboard, SVA); formal proof of the CSR block |
| 4 | Remaining tests (errors, reset, back-to-back, corners), DMA checker, regression and mutation runners; spec v0.4 |
| 5 | Functional coverage model and closure to 100%; formal proof of the DMA read engine |
| 6 | 8x8 array build: regression, coverage (waivers removed) and mutation on both sizes |
| 7 | Sign-off review, documentation |
