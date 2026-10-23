# Bug log

Every RTL bug found by verification goes here, with the evidence. The DUT RTL was written with
an AI assistant from `docs/spec.md`, so this log also measures how trustworthy that RTL was.

How to add a bug
- Give it the next ID. Fill in every column.
- **Found by** names the test and seed (or formal property) that first failed.
- **Category**: spec misread, boundary/off-by-one, protocol (AXI rule), concurrency/ordering,
  reset, arithmetic/numerics, other.
- **Locked by** names the test that now fails on the buggy RTL and passes on the fix.

| ID | Date | Found by | Symptom | Root cause | Category | Fix (commit) | Locked by |
|----|------|----------|---------|------------|----------|--------------|-----------|
|    |      |          |         |            |          |              |           |

## Result (2026-10-23, end of week 7)
**No RTL bug was found.** The table is empty on purpose: the designer RTL passed every UVM test
(17 tests x 20 seeds x ARRAY_N 4 and 8) and both formal proofs. An empty bug log only means
something if the verification could have found bugs, so that was measured separately:

| Evidence | Result |
|---|---|
| Simulation mutation (`sim/mutate.py`): realistic RTL bugs injected one at a time | 16/16 caught, at ARRAY_N = 4 and 8 |
| Formal mutation, CSR (`formal/csr/mutants.py`) | 10/10 bugs killed, 1 safe change proven |
| Formal mutation, DMA read (`formal/dma_rd/mutants.py`), spec properties only | 9/9 bugs killed, 2 safe changes proven |
| Functional coverage | 100% of 386 bins, no waivers |

What verification did find (not RTL bugs, so not in the table):
- **Spec gaps**, answered by the designer and fixed in the spec: vplan §9 Q1–Q6 (Q6, the minimum
  reset pulse, was found by `reset_midjob_test` and became spec v0.4).
- **Testbench and tool issues**, fixed in the testbench or flow (details in the commit messages):
  the saturation-edge stimulus hole (a surviving mutant), Xcelium not sampling covergroups
  without `-cov_cgsample`, the deprecated `uvm_component::check()` hook, Yosys turning a constant
  `case` into a ROM that induction treats as free state.

## Notes
- Bugs found in the **testbench** itself are not listed here; they go in the commit messages.
- Designer smoke tests (`tb/smoke/`) passed before hand-off on 2026-10-22, so every bug in this
  table was found by the UVM environment or formal.
