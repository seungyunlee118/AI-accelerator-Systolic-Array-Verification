# SA-GEMM: Systolic-Array INT8 Matrix-Multiply Accelerator — Design Spec v0.1

## 1. Overview
SA-GEMM computes `C = A × B` where `A` is M×K and `B` is K×N signed INT8 matrices, and
`C` is an M×N signed INT32 matrix. Software programs the job through an AXI4-Lite CSR
port; the accelerator fetches `A`/`B` from memory and writes `C` back through its own
AXI4 master (DMA), then raises an interrupt.

```
 AXI4-Lite slave ──► CSR ──► Controller FSM ──► DMA (AXI4 master) ◄──► memory
                                  │              │
                                  ▼              ▼
                     A/B buffers ──► N×N output-stationary PE array
                                                       irq ◄── IRQ logic
```

## 2. Parameters
| Name     | Default | Meaning                                   |
|----------|---------|-------------------------------------------|
| `ARRAY_N`| 4       | PE array is ARRAY_N × ARRAY_N (8 for final)|
| `MAX_DIM`| 64      | Max value of M, N, K                      |
| `DATA_W` | 8       | Input element width (signed)              |
| `ACC_W`  | 32      | Accumulator / output element width (signed)|
| `AXI_DW` | 64      | AXI4 master data width (bytes per beat = 8)|

## 3. Interfaces
- `clk`, `rst_n`: single clock; asynchronous active-low reset.
- AXI4-Lite slave `s_axil_*`: 32-bit address, 32-bit data, `wstrb` honored per byte.
  Single outstanding transaction per direction; AW and W may arrive in either order.
- AXI4 master `m_axi_*`: 32-bit address, 64-bit data. Signals present:
  AW(`awid[3:0] awaddr awlen[7:0] awsize[2:0] awburst[1:0] awvalid awready`),
  W(`wdata wstrb[7:0] wlast wvalid wready`), B(`bid bresp bvalid bready`),
  AR(`arid araddr arlen arsize arburst arvalid arready`),
  R(`rid rdata rresp rlast rvalid rready`). Cache/prot/lock/qos/region are not present.
- `irq`: level-high, `irq = |(IRQ_STATUS & IRQ_EN)`.

## 4. CSR map (AXI4-Lite, 32-bit registers)
| Offset | Name       | Bits     | Access | Reset       | Description |
|--------|------------|----------|--------|-------------|-------------|
| 0x00   | CTRL       | [0] START| W      | 0           | Write 1 to start a job. Always reads 0. |
| 0x04   | STATUS     | [0] BUSY | RO     | 0           | 1 while a job is running |
|        |            | [7:4] ERR_CODE | RO | 0         | Error code of the last job (see §7) |
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
| 0x30   | VERSION    | [31:0]   | RO     | 0x5341_0001 | Design ID / version |

- Unused bits read 0; writes to them are ignored.
- Writes to RO registers are ignored and return OKAY.
- Any offset not listed above returns SLVERR (reads return data 0).
- All configuration registers are sampled when START is accepted. Writing them while
  BUSY is allowed but does not affect the running job.
- Writing START while BUSY is ignored (no error, no effect on the running job).

## 5. Memory layout
All matrices are row-major and little-endian.
- `A[r][c]` (INT8) is at `A_BASE + r*A_STRIDE + c`.
- `B[r][c]` (INT8) is at `B_BASE + r*B_STRIDE + c`.
- `C[r][c]` (INT32) is at `C_BASE + r*C_STRIDE + 4*c`.

## 6. Operation
1. Software programs DIMS, the base/stride registers and IRQ_EN, then writes CTRL.START=1.
2. The configuration is checked (§7). On a configuration error the job ends
   immediately: no AXI master traffic, ERR_CODE is set and IRQ_STATUS.ERR is set.
3. Otherwise BUSY=1 and the DUT:
   1. reads all M rows of A into the A buffer,
   2. reads all K rows of B into the B buffer,
   3. computes the output in ARRAY_N×ARRAY_N tiles, row-major over tiles
      (tile row index outer, tile column index inner), writing each tile's
      valid C elements to memory before computing the next tile.
4. After the last write response is received: BUSY=0, ERR_CODE=0, IRQ_STATUS.DONE=1,
   CYCLES is updated.

Arithmetic: products are exact (16-bit), accumulation is INT32. With MAX_DIM=64 the
accumulator cannot overflow.

### 6.1 DMA rules (AXI4 master)
- `AxSIZE` is always 3 (8 bytes), `AxBURST` is always INCR, `AxID` is always 0.
- A burst never crosses a 4 KB boundary and is at most 8 beats (`AxLEN` ≤ 7).
- At most one read burst and one write burst are outstanding at any time.
- Reads: each matrix row is fetched with bursts covering `[row_addr, row_addr + K)` for A
  (or `+ N` for B), rounded out to whole 8-byte beats. The DUT may read up to 7 bytes past
  the end of a row inside the last beat, never more.
- Writes: only the bytes of valid C elements are written; `WSTRB` masks the rest.
  The DUT never writes outside the C elements of the current job.
- `AWVALID` for a burst is asserted before or together with its first `WVALID`.

## 7. Error handling
| ERR_CODE | Name      | Cause |
|----------|-----------|-------|
| 0        | NONE      | Last job completed successfully |
| 1        | BAD_DIM   | M, N or K is 0 or greater than MAX_DIM |
| 2        | BAD_ADDR  | Any of A/B/C_BASE or A/B/C_STRIDE is not a multiple of 8, or C_STRIDE < 4×N |
| 3        | RD_ERR    | A read returned `RRESP` ≠ OKAY |
| 4        | WR_ERR    | A write returned `BRESP` ≠ OKAY |

BAD_DIM is checked before BAD_ADDR. On RD_ERR/WR_ERR the DUT stops issuing new bursts,
completes every outstanding burst (accepting all R beats and B responses), then ends the
job with BUSY=0 and IRQ_STATUS.ERR=1. The contents of C are undefined after an error.

## 8. Reset
`rst_n` is asynchronous. Reset aborts any running job and returns all registers to their
reset values. The DUT drops all AXI valid signals during reset.
