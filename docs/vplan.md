# SA-GEMM Verification Plan v1.0 (owner: Seungyun Lee)

Traces to `spec.md` v0.3.

How to read this document
- §3 lists every feature in one table. §4 explains the hard ones in detail.
- Each detailed feature answers five questions: **what must be true** (requirement),
  **what could break** (bug hypotheses), **how we make it happen** (stimulus), **how we know
  it is right** (checker), and **how we know we exercised it** (coverage).
- Checkers are numbered `CHK-xx` (§5), covergroups `CG-xx` (§6), tests in §7.
- Priority: **P0** = must close before sign-off, **P1** = should close, **P2** = nice to have.

## 1. Scope
- **In scope:** the `sa_top` block as specified in `spec.md`: CSR block, controller, DMA
  (AXI4 master), A/B buffers, PE array, output stage, interrupts, errors, reset.
  `ARRAY_N` = 4 first, then 8.
- **Out of scope:** gate-level simulation, power, timing, performance targets beyond the
  CYCLES counter being sane, address wrap-around past 2^32 (undefined by spec §5), and
  multiple clock domains (the design has one clock).

## 2. Testbench architecture
```
                      ┌──────────────────────── uvm_env ─────────────────────────┐
  test ─► virtual     │  axil_agent (active, CPU role) ─► RAL model + predictor   │
          sequence ──►│        │ AXI4-Lite                                         │
                      │        ▼                                                   │
                      │   ┌───────── DUT sa_top ─────────┐   AXI4                  │
                      │   │ CSR ─► ctrl ─► DMA ──────────┼──────► axi_mem_agent    │
                      │   │        A/B buf ─► PE ─► outq │       (reactive slave)  │
                      │   └──────────── irq ─────────────┘       + memory model    │
                      │                                                            │
                      │  job_scoreboard: config snapshot at START, golden GEMM +   │
                      │      requant model, result and containment checks at end   │
                      │  dma_checker: address legality, outstanding/ID rules       │
                      │  coverage collectors (CG-01..CG-09)                         │
                      └────────────────────────────────────────────────────────────┘
  tb_top: clock, reset driver, interfaces, SVA bound to both AXI ports and the CSR block
```

| Component | Role |
|---|---|
| `axil_agent` (active) | Plays the CPU. Drives AXI4-Lite reads/writes with knobs for AW/W ordering, WSTRB, and B/R back-pressure. Reused from the AXI4-Lite project, with its handshake bug and `bus2reg` response bug fixed. |
| RAL model + explicit predictor | `uvm_reg` model of the 15 registers (W1C, RO, write-only START). Sequences use `reg.write()/read()`; the predictor keeps the mirror up to date from the AXI4-Lite monitor. |
| `axi_mem_agent` (reactive slave) | Plays memory. A sparse byte memory (reused from the AXI4-Full project's reference model) answers the DUT's AR/AW/W. Knobs: response latency, ready back-pressure, out-of-order return across IDs, beat interleaving, and RRESP/BRESP error injection. |
| `job_scoreboard` | At START, snapshots the configuration and the A/B bytes in memory. At the end of the job, computes the expected C with the golden model and compares every C element, then checks that nothing outside C changed (sentinel). Also predicts BUSY, ERR_CODE, IRQ_STATUS and CYCLES behavior. |
| Golden model | GEMM plus the §7 output stage, written from the spec. DPI-C if C compiles on the server (glibc-devel is missing, to be checked in week 1); otherwise a pure SystemVerilog class using `longint` math. It must not share any code with the RTL. |
| `dma_checker` | Watches the AXI4 port: every AR must fall inside a legal A/B row window, every enabled write byte must be a C element, read-ID rules hold. |
| SVA | AXI4 protocol (reused `axi4_sva`, reporting through `uvm_error`), DMA-specific rules, AXI4-Lite protocol, `irq` consistency. |
| Virtual sequences | `job_vseq`: fill memory (backdoor), program registers through RAL, start, wait for `irq` or poll `IRQ_STATUS`, clear the interrupt. Other vseqs layer errors, resets and register traffic on top. |

## 3. Feature index
| ID | Spec § | Feature | P | Checkers | Coverage | Tests |
|---|---|---|---|---|---|---|
| **CSR** | | | | | | |
| F-CSR-01 | 4 | Every register has its reset value; VERSION = 0x5341_0002 | P0 | CHK-07 | CG-01 | `csr_reset_test` |
| F-CSR-02 | 4 | RW registers keep only their writable bits; unused bits read 0 | P0 | CHK-07 | CG-01 | `csr_rw_test` |
| F-CSR-03 | 3, 4 | Byte strobes: only lanes with WSTRB=1 change | P1 | CHK-07 | CG-01 | `csr_rw_test` |
| F-CSR-04 | 3 | AW and W accepted in any order; B/R back-pressure honored | P0 | CHK-07, CHK-05 | CG-01 | `csr_rw_test` |
| F-CSR-05 | 4 | Unmapped offset gives SLVERR, no side effect; RO write ignored with OKAY; decode ignores addr[31:8] and [1:0] | P0 | CHK-07 | CG-01 | `csr_access_test` |
| F-CSR-06 | 4 | START needs wstrb[0]=1, reads 0, is ignored while BUSY | P0 | CHK-09 | CG-07 | `b2b_jobs_test` |
| F-CSR-07 | 4 | Config writes during BUSY do not affect the running job | P0 | CHK-01, CHK-09 | CG-07 | `b2b_jobs_test` |
| F-CSR-08 | 4 | IRQ_STATUS is sticky W1C; irq = OR of (IRQ_STATUS AND IRQ_EN); set wins over same-cycle clear | P0 | CHK-07, CHK-08 | CG-01 | `csr_irq_test` |
| **Datapath** | | | | | | |
| F-DP-01 | 6 | C = A × B is correct for every M, N, K in 1..64 | P0 | CHK-01 | CG-02 | `gemm_rand_test`, `gemm_dim_test` |
| F-DP-02 | 5, 6.1 | Edge tiles: every C element written, nothing outside C written | P0 | CHK-01, CHK-02, CHK-03 | CG-02, CG-05 | `gemm_edge_test` |
| F-DP-03 | 5 | Strides: gaps between rows, and A/B strides smaller than the row (overlap) | P1 | CHK-01, CHK-04 | CG-02 | `gemm_stride_test` |
| F-DP-04 | 6 | Extreme inputs (−128 × −128 summed over K = 64) do not overflow | P0 | CHK-01 | CG-03 | `gemm_quant_test` |
| F-DP-05 | 6 | Back-to-back jobs: no state leaks from one job to the next | P0 | CHK-01, CHK-09 | CG-07 | `b2b_jobs_test` |
| F-DP-06 | 6 | Completion: BUSY falls and DONE is set only after the last B response; CYCLES updated | P0 | CHK-09 | CG-07 | all job tests |
| **DMA** | | | | | | |
| F-DMA-01 | 6.1 | AXI4 protocol: VALID held until READY, payload stable, LAST on the right beat, no X | P0 | CHK-05 | — | all tests |
| F-DMA-02 | 6.1 | Burst shape: size 8 B, INCR, at most 8 beats, never crosses 4 KB | P0 | CHK-05 | CG-04 | `dma_4k_test` |
| F-DMA-03 | 6.1 | Each row read covers its bytes, over-reads at most 7 bytes, reads nothing else | P0 | CHK-04 | CG-04 | `gemm_rand_test` |
| F-DMA-04 | 6.1 | At most 4 reads outstanding, distinct ARIDs 0..3, ID reused only after RLAST | P0 | CHK-06 | CG-04 | `dma_ooo_test` |
| F-DMA-05 | 6.1 | Out-of-order and interleaved R data land in the right buffer place | P0 | CHK-01, CHK-06 | CG-04 | `dma_ooo_test` |
| F-DMA-06 | 6.1 | Writes: one outstanding, AWID 0, AW not after first W, WSTRB only on C bytes | P0 | CHK-03, CHK-06 | CG-05 | `gemm_edge_test` |
| F-DMA-07 | 6.1 | Random and long back-pressure on every channel does not break anything | P0 | CHK-01, CHK-05 | CG-04, CG-05 | `dma_backpressure_test` |
| **Output stage** | | | | | | |
| F-OUT-01 | 7 | INT32 output, ReLU on and off | P0 | CHK-01 | CG-03 | `gemm_quant_test` |
| F-OUT-02 | 7 | Requant: SCALE and SHIFT over their full range, ties round toward +infinity | P0 | CHK-01 | CG-03 | `gemm_quant_test` |
| F-OUT-03 | 7 | Saturation at −128 and 127; ReLU applied before the clamp | P0 | CHK-01 | CG-03 | `gemm_quant_test` |
| **Errors** | | | | | | |
| F-ERR-01 | 8 | BAD_DIM: no bus traffic, BUSY never set, ERR_CODE 1, priority over BAD_ADDR | P0 | CHK-09 | CG-06 | `err_cfg_test` |
| F-ERR-02 | 8 | BAD_ADDR: each base/stride misaligned; C_STRIDE below E×N in each mode | P0 | CHK-09 | CG-06 | `err_cfg_test` |
| F-ERR-03 | 8 | RD_ERR: stop new bursts, drain all outstanding reads, then end with ERR | P0 | CHK-10, CHK-09 | CG-06 | `err_bus_test` |
| F-ERR-04 | 8 | WR_ERR: same rules on the write side | P0 | CHK-10, CHK-09 | CG-06 | `err_bus_test` |
| F-ERR-05 | 6, 8 | After any error the next job succeeds; DONE and ERR are never set together | P0 | CHK-01, CHK-09 | CG-06 | `err_cfg_test`, `err_bus_test` |
| **Reset** | | | | | | |
| F-RST-01 | 9 | Reset while idle restores every register | P0 | CHK-07 | CG-08 | `csr_reset_test` |
| F-RST-02 | 9 | Reset mid-job (reading, computing, writing) drops all valids; the next job works | P0 | CHK-11, CHK-01 | CG-08 | `reset_midjob_test` |

## 4. Feature details (the hard ones)

### F-ERR-01 — Bad dimensions (spec §6 step 2, §8)
- **Requirement:** When START is accepted with M, N or K equal to 0 or greater than 64, the
  job ends with BUSY never asserted, no AXI master traffic, `ERR_CODE = 1`,
  `IRQ_STATUS.ERR = 1` and `CYCLES = 0`. BAD_DIM wins over BAD_ADDR.
- **What could break:**
  - Off-by-one bound (64 rejected, or 65 accepted).
  - Only one of M/N/K checked.
  - The 7-bit fields allow 65..127; the check might look at fewer bits.
  - DMA starts anyway and then stops, so some AR traffic leaks out.
  - BAD_ADDR reported when both errors are present.
  - The error state sticks, so the next good job fails or keeps ERR_CODE.
- **Stimulus:** DIMS with each of M, N, K from {0, 1, 64, 65, 127} while the other two are
  valid; repeat with a misaligned A_BASE (priority case); always follow with one good job.
- **Checker:** CHK-09 predicts the ERR_CODE and requires zero AR/AW handshakes and BUSY low
  from START to the ERR event; CHK-08 checks `irq`.
- **Coverage:** CG-06 `err_code` × `dim_class`, and `bad_dim × bad_addr`.

### F-DP-02 — Edge tiles and write containment (spec §5, §6.1 Writes, §7)
- **Requirement:** For any M, N in 1..64, every C[r][c] with r < M, c < N is written with
  the §7 value using element size E (4 or 1). No other byte is written.
- **What could break:**
  - Padded results of the last tile row/column get written past N or M.
  - Wrong WSTRB on a partial beat (odd N in INT32 mode, any N in INT8 mode).
  - Row address uses `E*N` instead of C_STRIDE, so the gap between rows is overwritten.
  - A C row write crosses a 4 KB boundary.
- **Stimulus:** M mod 4 and N mod 4 over all residues; K random; REQ_EN 0 and 1; C_STRIDE
  equal to and larger than `E*N`; C_BASE placed so rows cross 4 KB.
- **Checker:**
  - CHK-02: before START, the memory model paints C rows, the gaps and a 64-byte guard band
    around C with a sentinel pattern. After DONE, every non-C byte must still hold it.
  - CHK-03: per beat, the bytes enabled by WSTRB must be C element bytes. This flags the
    exact failing beat instead of failing at the end.
  - CHK-01: every C element equals the golden model.
- **Coverage:** CG-02 `m_mod4 × n_mod4 × req_en`, `c_gap`; CG-05 WSTRB shape; CG-04/05
  4 KB crossing.

### F-DMA-04 / F-DMA-05 — Outstanding, out-of-order and interleaved reads (spec §6.1)
This is the heart of the project.
- **Requirement:**
  1. No more than 4 read bursts are outstanding (AR accepted, RLAST not yet received).
  2. Each outstanding burst has a different ARID in 0..3.
  3. An ARID is reused only after its burst's RLAST.
  4. R beats may arrive in any order across IDs, even interleaved beat by beat, and every
     beat still lands in the right row and byte of the A/B buffer.
- **What could break:**
  - The ID table (ID → which row, which beat) stores the wrong row, or the beat counter is
    shared between IDs instead of kept per ID, so interleaved beats go to the wrong place.
  - An ID is freed on the first beat instead of on RLAST and gets reused too early.
  - The outstanding counter is off by one: 5 outstanding, or stuck at 3.
  - The DUT only works when data returns in order (it was never tested any other way).
  - A burst split at a 4 KB boundary is treated as one burst, so the second half lands at
    the start of the row.
  - Deadlock: with 4 outstanding, the DUT waits for a free ID, but it frees IDs only in issue
    order, so a burst that finished out of order never releases its ID.
- **Stimulus:**
  - The memory responder holds R data for each burst for a random latency (for example
    20–200 cycles). Long latency is what makes the DUT reach 4 outstanding.
  - Out-of-order mode: when several bursts are ready, pick one at random, not the oldest.
  - Interleave mode: send one beat of a random ready burst at a time.
  - Short matrices (K ≤ 8, one beat per row) and long ones (K = 64, 8 beats) both, so
    interleaving actually has beats to mix.
- **Checker:**
  - CHK-01 (end to end): C must match the golden model.
    **Trap:** if two rows hold the same data, swapping them still gives a correct C. So the
    stimulus must give every row unique data (for example, row index encoded in the first
    byte), otherwise a swap bug is invisible.
  - CHK-06 (SVA on the AXI4 port): outstanding count ≤ 4, no ARID issued while that ID is
    still outstanding. These are rules about the bus itself, so an assertion catches them at
    the exact cycle; the scoreboard would only see a wrong result much later, or never.
  - CHK-04: every AR is inside a legal row window.
- **Coverage (CG-04):** outstanding count at each AR handshake {1,2,3,4}; ARIDs used
  {0,1,2,3}; "a burst completed before an older one" (out-of-order seen); "a beat of another
  ID arrived between two beats of a burst" (interleave seen); cross of outstanding = 4 with
  out-of-order seen; ARLEN {0, 1..6, 7}; row split at 4 KB.

### F-OUT-02 / F-OUT-03 — Requantization corners (spec §7)
- **Requirement:** For every element, the output equals the §7 formula: multiply by SCALE,
  divide by 2^SHIFT rounding ties toward +infinity, optional ReLU, clamp to [−128, 127].
- **What could break:** ties rounded away from zero instead of toward +infinity (only
  visible on negative .5 values); SHIFT = 0 path handled wrong; product overflows 32 bits
  when SCALE is large; ReLU applied after the clamp; clamp off by one (−129 or 128 leaks).
- **Stimulus:** choose A/B values to hit target accumulators. With K = 1 the accumulator is
  just `a × b`, so exact values are easy (for example a = −3, b = 1 with SHIFT = 1 gives a
  −1.5 tie). Larger K with constant rows gives large accumulators. Sweep SCALE over
  {0, 1, 2, random, 65535} and SHIFT over {0, 1, random, 30, 31}.
- **Checker:** CHK-01 with a golden model written independently from the spec formula in
  64-bit math (never reuse `sa_outq.sv`).
- **Coverage (CG-03):** per element: result class {in range, clamped high, clamped low,
  zeroed by ReLU}; tie seen {positive tie, negative tie}; SCALE and SHIFT bins; crosses
  of result class × RELU_EN, and tie × sign.

### F-ERR-03 — Read error with reads in flight (spec §8)
- **Requirement:** after an RRESP error, no new AR is issued; every outstanding burst is
  still accepted to its RLAST; then BUSY falls with `ERR_CODE = 3` and `IRQ_STATUS.ERR = 1`.
- **What could break:** the DUT stops accepting R beats (RREADY low forever), so the bus
  hangs; it issues more reads after the error; it ends the job before the in-flight bursts
  finish; DONE gets set as well as ERR.
- **Stimulus:** inject an error on a random beat of a random burst while 1–4 reads are
  outstanding; also on the very first and the very last burst of a job.
- **Checker:** CHK-10 (no AR after the first error response; BUSY falls only after every
  outstanding RLAST); CHK-09 (codes and flags); per-job watchdog for hangs.
- **Coverage (CG-06):** error phase {A load, B load} × outstanding count at the error.

### F-RST-02 — Reset in the middle of a job (spec §9)
- **Requirement:** reset at any time drops every AXI valid, returns registers to reset
  values, and the next job after reset works.
- **What could break:** a valid stays high through reset; a stale ID table entry survives
  reset and corrupts the next job; the CSR keeps BUSY.
- **Stimulus:** assert reset at a random time in each phase (reading A, reading B,
  computing, writing C). The memory model drops all pending transactions on reset (the
  memory side is reset with the chip), then a normal job runs.
- **Checker:** CHK-11 (no valid during reset), CHK-07 (reset values), CHK-01 on the next job.
- **Coverage (CG-08):** reset phase × outstanding reads at reset.

## 5. Checkers and assertions
| ID | Where | Property |
|---|---|---|
| CHK-01 | job_scoreboard | Every C element equals the golden GEMM + §7 output stage result |
| CHK-02 | job_scoreboard + memory model | Bytes outside the C elements (row gaps, 64 B guard bands) still hold the sentinel after the job |
| CHK-03 | memory model (per beat) | Every byte enabled by WSTRB is a C element byte of the current job |
| CHK-04 | dma_checker | Every AR lies inside a legal A or B row window; over-read at most 7 bytes; every needed byte is requested |
| CHK-05 | SVA (reused `axi4_sva` and AXI4-Lite SVA) | VALID held until READY, payload stable while stalled, LAST position, no X on qualified signals, AxSIZE = 3, INCR, AxLEN ≤ 7, no 4 KB crossing |
| CHK-06 | SVA (new, DMA rules) | Reads outstanding ≤ 4; no ARID reused while outstanding; at most one write outstanding; AWID = 0; no W beat before its AW |
| CHK-07 | RAL | Read values match the mirror (including W1C prediction and reset values); SLVERR exactly on unmapped offsets |
| CHK-08 | SVA bound to the CSR block | `irq` equals the OR of (IRQ_STATUS AND IRQ_EN) every cycle |
| CHK-09 | job_scoreboard | Per job: expected ERR_CODE, DONE vs ERR, BUSY never set on config errors, zero bus traffic on config errors, CYCLES = 0 on config errors and > 0 otherwise |
| CHK-10 | SVA + job_scoreboard | After an error response: no new AR/AW; BUSY falls only after every outstanding burst completes |
| CHK-11 | SVA | All AXI valids low while reset is asserted |
| CHK-12 | test base | Per-job watchdog and UVM timeout catch hangs |

All SVA failures report through `uvm_error` so they fail the test (lesson from the L1 cache
project, where `$error` assertions failed silently).

## 6. Coverage model
| Covergroup | Sampled | Coverpoints / bins | Crosses | Goal |
|---|---|---|---|---|
| CG-01 csr | each AXI4-Lite access | register × access (read, write); AW/W order {AW first, W first, same cycle}; WSTRB {full, partial}; unmapped; RO write; W1C clear with event in the same cycle | register × access | 100% |
| CG-02 job_cfg | each START | M, N, K bins {1, 2–3, 4, 5–7, 8, 9–63, 64}; M mod 4, N mod 4; C gap {none, gap}; A/B stride {gap, exact, overlap} | m_mod4 × n_mod4 × req_en | 100% |
| CG-03 output | each C element | result class {in range, clamp high, clamp low, ReLU zero}; tie {positive, negative}; SCALE {0, 1, mid, 65535}; SHIFT {0, 1, mid, 31}; REQ_EN, RELU_EN | class × relu_en; tie × req_en | 100% |
| CG-04 dma_read | each AR / burst end | outstanding at AR {1,2,3,4}; ARID {0..3}; ARLEN {0, 1–6, 7}; 4 KB split; out-of-order seen; interleave seen; RRESP error | outstanding=4 × out-of-order | 100% |
| CG-05 dma_write | each W beat / B | AWLEN; WSTRB shape {full, low half, high half, single byte, other}; BRESP error; 4 KB split | wstrb shape × req_en | 100% |
| CG-06 errors | each job end | ERR_CODE {0..4}; error phase {config, A load, B load, C write}; outstanding at error; BAD_DIM × BAD_ADDR together | err_code × phase | 100% |
| CG-07 job_flow | each START | START while BUSY; config write while BUSY; back-to-back jobs; poll vs interrupt completion | — | 100% |
| CG-08 reset | each reset | phase {idle, A load, B load, compute, C write}; outstanding at reset | phase × outstanding | 100% |
| CG-09 array (P2) | per job | ARRAY_N 4 and 8 | — | 100% |

## 7. Test list
| Test | Purpose | Main features |
|---|---|---|
| `csr_reset_test` | `uvm_reg_hw_reset_seq` plus reset-while-idle | F-CSR-01, F-RST-01 |
| `csr_rw_test` | RAL bit-bash plus random WSTRB and AW/W ordering | F-CSR-02..04 |
| `csr_access_test` | Unmapped offsets, RO writes, address aliasing | F-CSR-05 |
| `csr_irq_test` | W1C, enable masking, set vs clear in the same cycle | F-CSR-08 |
| `gemm_smoke_test` | One 4×4×4 job, ideal memory (first test to bring up) | F-DP-01 |
| `gemm_dim_test` | Directed dimension edges {1, 3, 4, 5, 63, 64} | F-DP-01 |
| `gemm_edge_test` | All M/N residues, both output modes, sentinel checks | F-DP-02, F-DMA-06 |
| `gemm_stride_test` | Gaps and overlapping strides | F-DP-03 |
| `gemm_quant_test` | Requant and ReLU corners, extreme inputs | F-DP-04, F-OUT-01..03 |
| `gemm_rand_test` | Everything random (main coverage closer) | most |
| `dma_ooo_test` | Long latency, out-of-order and interleaved returns | F-DMA-04, F-DMA-05 |
| `dma_backpressure_test` | Random and long READY/VALID stalls on every channel | F-DMA-07 |
| `dma_4k_test` | Rows and C writes across 4 KB boundaries | F-DMA-02 |
| `b2b_jobs_test` | Back-to-back jobs, START while BUSY, config writes while BUSY | F-CSR-06, F-CSR-07, F-DP-05 |
| `err_cfg_test` | BAD_DIM and BAD_ADDR sweeps, each followed by a good job | F-ERR-01, F-ERR-02, F-ERR-05 |
| `err_bus_test` | RRESP/BRESP errors with reads in flight | F-ERR-03..05 |
| `reset_midjob_test` | Reset in each job phase, then a good job | F-RST-02 |

Seeds: every test runs at least 4 seeds in the daily regression and 20 seeds before sign-off.

## 8. Sign-off criteria
- **Functional coverage:** every P0 covergroup at 100%; P1 at 100% or with a reviewed waiver.
- **Code coverage:** statement and branch ≥ 95%, toggle ≥ 90%, every gap explained or
  waived. The server has no IMC, so per-run numbers plus a script that merges bin hits are
  used until a merge tool is available.
- **Regression:** all tests × 20 seeds pass with 0 UVM_ERROR, 0 UVM_FATAL, 0 SVA failures.
- **Bugs:** no open P0/P1 bugs; every fixed bug has a test that fails without the fix.
- **Testbench quality:** mutation campaign kills ≥ 95% of non-equivalent mutants.

## 9. Open questions (to the designer)
| # | Spec § | Question | Answer (designer) | Status |
|---|---|---|---|---|
| Q1 | 6, 4 | On a configuration error, does BUSY go high at all, and what is CYCLES afterwards? | BUSY is never asserted; CYCLES is set to 0. Added to spec v0.3 §6 step 2. | closed |
| Q2 | 6, 8 | On a failed job, is DONE also set? | No. DONE only on success, ERR only on failure, never both. Spec v0.3 §6 step 5. | closed |
| Q3 | 5 | Is A_STRIDE < K (overlapping rows) legal? | Yes, rows are read exactly as the formula says. Spec v0.3 §5. | closed |
| Q4 | 5 | What happens if an address range wraps past 2^32? | Undefined; software must not do it. The TB constrains all regions below 2^32. Spec v0.3 §5. | closed |
| Q5 | 9 | After a mid-job reset, can stale R/B responses still arrive? | The memory side is reset with the chip, so no. The TB memory model drops all pending transactions on reset. (TB assumption, not a DUT rule.) | closed |
