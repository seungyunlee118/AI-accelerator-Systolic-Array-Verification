# SA-GEMM: Systolic-Array INT8 Matrix-Multiply Accelerator — Design Spec v0.4

Revision history
| Version | Change |
|---------|--------|
| 0.1 | Initial: single-outstanding DMA, INT32 output |
| 0.2 | Up to 4 outstanding read bursts with out-of-order / interleaved R data; requantized INT8 output (QCFG, QSCALE); ReLU |
| 0.3 | Clarifications from vplan review: BUSY/CYCLES on configuration errors, DONE vs ERR, overlapping strides, address range |
| 0.4 | Reset: minimum assertion time and synchronous release (found by the mid-job reset test) |

## 1. Overview
SA-GEMM computes `C = A × B` where `A` is M×K and `B` is K×N signed INT8 matrices. The raw
result is a signed INT32 matrix; optionally it is requantized to INT8. Software programs
the job through an AXI4-Lite CSR port; the accelerator fetches `A`/`B` from memory and
writes `C` back through its own AXI4 master (DMA), then raises an interrupt.

```
 AXI4-Lite slave ──► CSR ──► Controller FSM ──► DMA (AXI4 master) ◄──► memory
                                  │              │
                                  ▼              ▼
                     A/B buffers ──► N×N output-stationary PE array ──► requant ──► C
                                                       irq ◄── IRQ logic
```

## 2. Parameters
| Name     | Default | Meaning                                    |
|----------|---------|--------------------------------------------|
| `ARRAY_N`| 4       | PE array is ARRAY_N × ARRAY_N (8 for final)|
| `MAX_DIM`| 64      | Max value of M, N, K                       |
| `DATA_W` | 8       | Input element width (signed)               |
| `ACC_W`  | 32      | Accumulator width (signed)                 |
| `AXI_DW` | 64      | AXI4 master data width (bytes per beat = 8)|
| `MAX_RD_OT` | 4    | Max outstanding read bursts                |

## 3. Interfaces
- `clk`, `rst_n`: single clock; asynchronous active-low reset.
- AXI4-Lite slave `s_axil_*`: 32-bit address, 32-bit data, `wstrb` honored per byte.
  Single outstanding transaction per direction; AW and W may arrive in either order.
- AXI4 master `m_axi_*`: 32-bit address, 64-bit data. Signals present:
  AW(`awid[3:0] awaddr awlen[7:0] awsize[2:0] awburst[1:0] awvalid awready`),
  W(`wdata wstrb[7:0] wlast wvalid wready`), B(`bid bresp bvalid bready`),
  AR(`arid[3:0] araddr arlen arsize arburst arvalid arready`),
  R(`rid[3:0] rdata rresp rlast rvalid rready`). Cache/prot/lock/qos/region are not present.
- `irq`: level-high, `irq = |(IRQ_STATUS & IRQ_EN)`.

## 4. CSR map (AXI4-Lite, 32-bit registers)
| Offset | Name       | Bits     | Access | Reset       | Description |
|--------|------------|----------|--------|-------------|-------------|
| 0x00   | CTRL       | [0] START| W      | 0           | Write 1 to start a job. Always reads 0. |
| 0x04   | STATUS     | [0] BUSY | RO     | 0           | 1 while a job is running |
|        |            | [7:4] ERR_CODE | RO | 0         | Error code of the last job (see §8) |
| 0x08   | IRQ_EN     | [0] DONE_EN, [1] ERR_EN | RW | 0 | Interrupt enables |
| 0x0C   | IRQ_STATUS | [0] DONE, [1] ERR | W1C | 0       | Sticky event flags; write 1 to clear |
| 0x10   | DIMS       | [6:0] M, [14:8] N, [22:16] K | RW | 0 | Matrix dimensions (valid: 1..MAX_DIM) |
| 0x14   | A_BASE     | [31:0]   | RW     | 0           | Byte address of A[0][0] |
| 0x18   | A_STRIDE   | [15:0]   | RW     | 0           | Bytes between consecutive A rows |
| 0x1C   | B_BASE     | [31:0]   | RW     | 0           | Byte address of B[0][0] |
| 0x20   | B_STRIDE   | [15:0]   | RW     | 0           | Bytes between consecutive B rows |
| 0x24   | C_BASE     | [31:0]   | RW     | 0           | Byte address of C[0][0] |
| 0x28   | C_STRIDE   | [15:0]   | RW     | 0           | Bytes between consecutive C rows |
| 0x2C   | CYCLES     | [31:0]   | RO     | 0           | Clock cycles BUSY was high during the last job |
| 0x30   | VERSION    | [31:0]   | RO     | 0x5341_0002 | Design ID / version |
| 0x34   | QCFG       | [0] REQ_EN, [1] RELU_EN, [12:8] SHIFT | RW | 0 | Output stage config (§7) |
| 0x38   | QSCALE     | [15:0] SCALE | RW | 0           | Requantization multiplier, unsigned (§7) |

- The CSR block decodes address bits [7:2]; bits [31:8] and [1:0] are ignored.
- Unused bits read 0; writes to them are ignored.
- Writes to RO registers are ignored and return OKAY.
- Any offset not listed above returns SLVERR (reads return data 0, writes have no effect).
- CTRL.START takes effect only when byte lane 0 is written (`wstrb[0] = 1`).
- IRQ_STATUS: if a hardware event sets a bit in the same cycle that software clears it,
  the bit ends up set.
- All configuration registers (DIMS, bases, strides, QCFG, QSCALE) are sampled when START
  is accepted. Writing them while BUSY is allowed but does not affect the running job.
- Writing START while BUSY is ignored (no error, no effect on the running job).

## 5. Memory layout
All matrices are row-major and little-endian.
- `A[r][c]` (INT8) is at `A_BASE + r*A_STRIDE + c`.
- `B[r][c]` (INT8) is at `B_BASE + r*B_STRIDE + c`.
- `C[r][c]` is at `C_BASE + r*C_STRIDE + E*c`, where the element size `E` is
  4 bytes (INT32) when `QCFG.REQ_EN = 0` and 1 byte (INT8) when `QCFG.REQ_EN = 1`.
- A_STRIDE may be smaller than K (and B_STRIDE smaller than N). Rows then overlap in memory
  and are read exactly as the formulas above say. (C_STRIDE has a minimum, see §8.)
- Software must keep every accessed address below 2^32. Address wrap-around is undefined.

## 6. Operation
1. Software programs DIMS, the base/stride registers, QCFG/QSCALE and IRQ_EN, then writes
   CTRL.START=1.
2. The configuration is checked (§8). On a configuration error the job ends
   immediately: BUSY is never asserted, there is no AXI master traffic, ERR_CODE is set,
   IRQ_STATUS.ERR is set and CYCLES is set to 0.
3. Otherwise BUSY=1 and the DUT:
   1. reads all M rows of A into the A buffer,
   2. reads all K rows of B into the B buffer,
   3. computes the output in ARRAY_N×ARRAY_N tiles, row-major over tiles
      (tile row index outer, tile column index inner), passes every element through the
      output stage (§7) and writes each tile's valid C elements to memory before
      computing the next tile.
4. After the last write response is received: BUSY=0, ERR_CODE=0, IRQ_STATUS.DONE=1,
   CYCLES is updated.
5. IRQ_STATUS.DONE is set only by a job that succeeds and IRQ_STATUS.ERR only by a job that
   fails; never both. ERR_CODE keeps the last job's code until the next job ends.

Arithmetic: products are exact (16-bit), accumulation is INT32. With MAX_DIM=64 the
accumulator cannot overflow.

### 6.1 DMA rules (AXI4 master)
- `AxSIZE` is always 3 (8 bytes) and `AxBURST` is always INCR.
- A burst never crosses a 4 KB boundary and is at most 8 beats (`AxLEN` ≤ 7).
- Reads:
  - Up to `MAX_RD_OT` (4) read bursts may be outstanding. Every outstanding read burst
    uses a distinct `ARID` in 0..3; an ID is reused only after that burst's RLAST beat.
  - The DUT accepts R beats in any order across IDs, including beat-level interleaving
    between different IDs. Beats of the same ID arrive in order (AXI4 rule).
  - The order in which read bursts are issued is not specified.
  - Each matrix row is fetched with bursts covering `[row_addr, row_addr + K)` for A
    (or `+ N` for B), rounded out to whole 8-byte beats. The DUT may read up to 7 bytes
    past the end of a row inside the last beat, never more.
- Writes:
  - At most one write burst is outstanding; `AWID` is always 0.
  - Only the bytes of valid C elements are written; `WSTRB` masks the rest.
    The DUT never writes outside the C elements of the current job.
  - `AWVALID` for a burst is asserted before or together with its first `WVALID`.

## 7. Output stage
Applied to every accumulator value `acc` (signed 32-bit) before it is written.

```
REQ_EN = 0 (INT32 output):
    out = RELU_EN ? max(acc, 0) : acc

REQ_EN = 1 (INT8 output):
    p   = acc * SCALE                      // exact; SCALE is unsigned 16-bit, p fits in 49 bits
    r   = (SHIFT == 0) ? p
                       : (p + 2**(SHIFT-1)) >>> SHIFT   // arithmetic shift = floor;
                                                        // ties round toward +infinity
    r   = RELU_EN ? max(r, 0) : r
    out = clamp(r, -128, 127)              // saturate to INT8
```
Examples (SCALE=1, SHIFT=1): acc=3 → 2, acc=-3 → -1, acc=-4 → -2.

## 8. Error handling
| ERR_CODE | Name      | Cause |
|----------|-----------|-------|
| 0        | NONE      | Last job completed successfully |
| 1        | BAD_DIM   | M, N or K is 0 or greater than MAX_DIM |
| 2        | BAD_ADDR  | Any of A/B/C_BASE or A/B/C_STRIDE is not a multiple of 8, or C_STRIDE < E×N (E from §5) |
| 3        | RD_ERR    | A read returned `RRESP` ≠ OKAY |
| 4        | WR_ERR    | A write returned `BRESP` ≠ OKAY |

BAD_DIM is checked before BAD_ADDR. On RD_ERR/WR_ERR the DUT stops issuing new bursts,
completes every outstanding burst (accepting all R beats and B responses), then ends the
job with BUSY=0, IRQ_STATUS.ERR=1 and CYCLES updated. The contents of C are undefined after
an error.

## 9. Reset
`rst_n` is asynchronous. Reset aborts any running job and returns all registers to their
reset values. The DUT drops all AXI valid signals during reset.

Assertion may happen at any time, without a clock. `rst_n` must then stay low for at least
two rising edges of `clk`, and it is released synchronously to `clk` (away from a rising edge),
as a reset synchronizer does. The DUT and every block on the same reset (such as the memory
behind the AXI4 port) see the reset this way; a pulse shorter than that is not a valid reset.
