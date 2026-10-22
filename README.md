# SA-GEMM: Systolic-Array INT8 GEMM Accelerator Verification

INT8 matrix-multiply accelerator (AXI4-Lite CSR + AXI4 DMA master + N×N output-stationary
PE array + requantization) verified with a UVM environment on Cadence Xcelium.

## Roles
- **Verification (UVM environment, verification plan, coverage, regression):** Seungyun Lee
- **DUT RTL:** written with an AI assistant from the spec in `docs/spec.md`, then treated as
  a third-party design under test.

## Architecture
<p align="center">
  <img src="docs/sa_gemm_block_diagram.svg" alt="SA-GEMM DUT block diagram" width="680">
</p>

1. The CPU (the UVM AXI4-Lite agent in simulation) programs the CSR block and writes `CTRL.START`.
2. The controller has the DMA engine fetch A and B from external memory over AXI4
   (up to 4 outstanding read bursts, out-of-order / interleaved responses).
3. The 4×4 output-stationary systolic array computes each output tile from the A/B buffers.
4. The output stage applies ReLU and optional INT8 requantization; the DMA engine writes C back.
5. On completion or error the CSR block raises `irq`.

Full details are in [`docs/spec.md`](docs/spec.md).

## Layout
| Path            | Contents |
|-----------------|----------|
| `docs/spec.md`  | Design specification (DUT contract) |
| `docs/vplan.md` | Verification plan |
| `docs/ko/`      | Korean translations of the spec and the verification plan (the English files are authoritative) |
| `rtl/`          | DUT RTL |
| `tb/smoke/`     | Designer smoke tests |
| `sim/`          | Simulation run directory (outputs are git-ignored) |
| `sync.sh`       | Copies the repo to the Xcelium server |

## Status
- [x] Spec v0.2 (4 outstanding reads with out-of-order/interleaved R data, INT8 requantization)
- [x] PE + systolic array RTL, smoke test passing (80 cases, Xcelium 24.09)
- [x] CSR (AXI4-Lite) RTL, smoke test passing (AW/W ordering, strobes, W1C set-vs-clear race)
- [x] Output stage (ReLU + requantization) RTL, smoke test passing (21,851 checks)
- [ ] DMA (AXI4 master), controller, top
- [ ] UVM environment (RAL, AXI memory responder, DPI-C golden model, coverage)
- [ ] Regression, coverage closure, mutation campaign

## Workflow
Code is edited on a laptop and simulated on a Linux server with Xcelium.

```bash
./sync.sh                                   # laptop -> server (ssh alias "msd10")
ssh msd10                                   # or use the server's own terminal
cd ~/AI-accelerator-Systolic-Array-Verification/sim
```

Smoke tests (run inside `sim/`):
```bash
xrun -sv ../rtl/sa_pe.sv ../rtl/sa_array.sv ../tb/smoke/tb_sa_array.sv
xrun -sv ../rtl/sa_csr.sv  ../tb/smoke/tb_sa_csr.sv
xrun -sv ../rtl/sa_outq.sv ../tb/smoke/tb_sa_outq.sv
```
On this server Cadence tools need 64-bit mode: `export CDS_AUTO_64BIT=ALL` (or pass `-64bit`).
