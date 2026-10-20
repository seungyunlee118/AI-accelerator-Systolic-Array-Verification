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
- [x] Spec v0.1
- [x] PE + systolic array RTL, smoke test passing (80 cases, Xcelium 24.09)
- [ ] CSR (AXI4-Lite), DMA (AXI4 master), controller, top
- [ ] UVM environment (RAL, AXI memory responder, DPI-C golden model, coverage)
- [ ] Regression and coverage closure

## Run the smoke test (on the Xcelium server)
```bash
cd sim
xrun -64bit -sv ../rtl/sa_pe.sv ../rtl/sa_array.sv ../tb/smoke/tb_sa_array.sv
```
