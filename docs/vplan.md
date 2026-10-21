# SA-GEMM Verification Plan (owner: Seungyun Lee)

How to use this document
- Every feature traces to a spec section (`spec.md` v0.2).
- Each feature answers five questions: **what must be true**, **what could break**,
  **how we make it happen** (stimulus), **how we know it is right** (checker), and
  **how we know we exercised it** (coverage).
- Priority: **P0** = must close before sign-off, **P1** = should close, **P2** = nice to have.
- Spec holes found while writing go to §9 Open questions and are sent to the designer.

## 1. Scope
- In scope:
- Out of scope:

## 2. Testbench architecture
(Agents, active/passive, memory model, RAL, scoreboard, reference model, coverage collectors.
Add a block diagram.)

## 3. Feature index
Go through the spec section by section. Expect roughly: §4 CSR 6–8, §5–6 data path 4–6,
§6.1 DMA 5–7, §7 output stage 3–5, §8 errors 4–6, §9 reset 1–3.

| ID   | Spec § | Feature (one line) | Priority | Status |
|------|--------|--------------------|----------|--------|
| F-01 | 8      | Bad dimensions end the job with BAD_DIM and no bus traffic | P0 | planned |
| F-02 | 5, 6.1 | Edge tiles: every C element written, nothing outside C written | P0 | planned |
| F-03 | 6.1    | Up to 4 outstanding reads; out-of-order / interleaved R data accepted | P0 | **exercise** |
|      |        |                    |          |        |

## 4. Feature details

### F-01 — Bad dimensions (spec §8, §6 step 2)  *(worked example)*
- **Requirement:** When START is accepted with M, N or K equal to 0 or greater than 64, the
  job ends with no AXI master traffic, `STATUS.ERR_CODE = 1`, `IRQ_STATUS.ERR = 1`, and
  `STATUS.BUSY = 0` afterwards. BAD_DIM takes priority over BAD_ADDR.
- **What could break:**
  - Off-by-one bound (`>= 64` rejected, or 65 accepted).
  - Only one of M/N/K checked.
  - The 7-bit fields allow 65..127; the check might look at fewer bits.
  - DMA starts anyway and then stops (some AR traffic leaks out).
  - BAD_ADDR reported when both errors are present.
  - The error state sticks: the next good job fails or keeps ERR_CODE.
- **Stimulus:** RAL-write DIMS with each of M, N, K taken from {0, 1, 64, 65, 127} while
  the other two are valid; repeat with a misaligned A_BASE as well (priority); always follow
  with one good job.
- **Checker:**
  - Predictor computes the expected ERR_CODE from the programmed registers.
  - AXI master monitor counts AR/AW handshakes between START and the ERR event; must be 0.
  - RAL read of STATUS and IRQ_STATUS; `irq` pin assertion `irq == |(IRQ_STATUS & IRQ_EN)`.
- **Coverage:** per dimension `{0, 1, [2:63], 64, [65:127]}`; cross
  `dim_class × err_code`; cross `bad_dim × bad_addr` to prove the priority case was hit.
- **Tests:** `err_cfg_test` (directed sweep), plus an error knob in `gemm_rand_test`.

### F-02 — Edge tiles and write containment (spec §5, §6.1 Writes, §7)  *(worked example)*
- **Requirement:** For any M, N in 1..64, including values that are not multiples of
  ARRAY_N, every C[r][c] with r < M, c < N is written with the §7 output value, using
  element size E = 4 (INT32) or 1 (INT8). No byte outside those elements is written.
- **What could break:**
  - Padded results of the last tile row/column get written (corrupting memory past N or M).
  - Wrong WSTRB on a partial beat (odd N in INT32 mode, any N in INT8 mode).
  - Row address uses `E*N` instead of C_STRIDE, so the gap between rows is overwritten.
  - C write bursts crossing a 4 KB boundary.
- **Stimulus:**
  - M mod 4 and N mod 4 over all residues {0,1,2,3}; K random; REQ_EN 0 and 1.
  - C_STRIDE equal to `E*N` (no gap) and larger (gap).
  - C_BASE placed so rows cross a 4 KB boundary.
- **Checker:**
  - Before START, the memory model fills C rows, row gaps and a 64-byte guard band before
    and after the C area with a sentinel pattern.
  - After DONE: every C element equals the golden model, and every non-C byte still holds
    the sentinel.
  - Per-beat check in the memory responder: the bytes enabled by WSTRB must be a subset of
    the expected C byte set. This flags the exact failing beat instead of failing at the end.
- **Coverage:** `m_mod4 × n_mod4 × req_en`; `c_gap` (no gap / gap); WSTRB shape on C writes
  (full, low part, high part, single byte); `c_row_crosses_4k`.
- **Tests:** `gemm_edge_test` (directed residue sweep), `gemm_rand_test`.

### F-03 — Outstanding and out-of-order reads (spec §6.1 Reads)  *(exercise: write this one)*
Answer these, then rewrite them in the same shape as F-01 and F-02:
1. **Requirement:** Rewrite the four read rules in §6.1 as testable sentences.
   (Hint: how many outstanding, which IDs, when an ID may be reused, what order R data may
   arrive in.)
2. **What could break:** List at least four bugs a DMA designer could make here.
   (Think about the table that maps an ID to "where do these beats go".)
3. **Stimulus:** What knobs must the memory responder have so that out-of-order and
   interleaved responses actually happen? How do you make sure the DUT really reaches
   4 outstanding?
4. **Checker:** End-to-end C comparison catches a lot, but not everything. When could two
   rows' data be swapped and C still be correct? How do you prevent that? Which rules need
   an assertion instead of the scoreboard?
5. **Coverage:** What proves the interesting cases happened? (Number outstanding, ID usage,
   arrival order, interleave.)

## 5. Checkers and assertions
| ID | Where (SVA / scoreboard / memory model) | Property |
|----|------------------------------------------|----------|
|    |                                          |          |

## 6. Coverage model
| Covergroup | Coverpoints / bins | Crosses | Goal |
|------------|--------------------|---------|------|
|            |                    |         |      |

## 7. Test list
| Test | Purpose | Sequences | Seeds |
|------|---------|-----------|-------|
|      |         |           |       |

## 8. Sign-off criteria
- Functional coverage:
- Code coverage:
- Regression:
- Open bugs:

## 9. Open questions (to the designer)
| # | Spec § | Question | Answer | Status |
|---|--------|----------|--------|--------|
| Q1 | 6, 4 | On a configuration error, does BUSY go high at all (even for one cycle), and what is CYCLES afterwards? | | open |
|    |        |          |        |        |
