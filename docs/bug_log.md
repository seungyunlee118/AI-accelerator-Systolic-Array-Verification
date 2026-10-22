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

## Notes
- Bugs found in the **testbench** itself are not listed here; they go in the commit messages.
- Designer smoke tests (`tb/smoke/`) passed before hand-off on 2026-10-22, so every bug in this
  table was found by the UVM environment or formal.
