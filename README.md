# SA-GEMM: Systolic-Array INT8 GEMM Accelerator Verification

INT8 matrix-multiply accelerator (AXI4-Lite CSR + AXI4 DMA master + N×N output-stationary
PE array) verified with a UVM environment on Cadence Xcelium.

| Path            | Contents |
|-----------------|----------|
| `docs/spec.md`  | Design specification (DUT contract) |
| `docs/vplan.md` | Verification plan |
| `rtl/`          | DUT RTL |
| `tb/smoke/`     | Designer smoke tests |
| `sim/`          | Simulation run directory (outputs are git-ignored) |

## Status
- [x] Spec v0.2 (4 outstanding reads with out-of-order/interleaved R data, INT8 requantization)
- [x] PE + systolic array RTL, smoke test passing (80 cases, Xcelium 24.09)
- [x] CSR (AXI4-Lite) RTL, smoke test passing (AW/W ordering, strobes, W1C set-vs-clear race)
- [x] Output stage (ReLU + requantization) RTL, smoke test passing (21,851 checks)
- [ ] DMA (AXI4 master), controller, top
- [ ] UVM environment (RAL, AXI memory responder, DPI-C golden model, coverage)
- [ ] Regression and coverage closure

## Run the smoke tests (on the Xcelium server)
```bash
cd sim
xrun -64bit -sv ../rtl/sa_pe.sv ../rtl/sa_array.sv ../tb/smoke/tb_sa_array.sv
xrun -64bit -sv ../rtl/sa_csr.sv  ../tb/smoke/tb_sa_csr.sv
xrun -64bit -sv ../rtl/sa_outq.sv ../tb/smoke/tb_sa_outq.sv
```
