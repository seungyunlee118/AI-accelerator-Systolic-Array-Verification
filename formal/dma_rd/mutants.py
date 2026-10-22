#!/usr/bin/env python3
"""Formal mutation check for the DMA read engine proof.

Each mutant is one small, realistic bug put into a copy of rtl/sa_dma_rd.sv (the bug list of
vplan F-DMA-04/05 plus protocol and error bugs). Bugs run the bounded task bmc_spec (small
commands, 25 cycles, helper invariants left out, so only spec properties can catch them) and
must FAIL with a counterexample from reset. Safe changes run the full proof and must still PASS.
The runner is ../mutlib.py.

  source ~/oss-cad-suite/environment
  python3 mutants.py              # all mutants
  python3 mutants.py id_free_any_beat no_4k_split
"""
import sys

sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent.parent))
import mutlib  # noqa: E402

HERE = mutlib.block_dir(__file__)
BLOCK = {"dir": HERE, "rtl": (HERE / "../../rtl/sa_dma_rd.sv").resolve(), "props": HERE / "sa_dma_rd_props.svh",
         "sby": HERE / "sa_dma_rd.sby", "task": "bmc_spec"}

# name: (original text, mutated text, expected result, what the bug is[, task])
# For several edits, the first field is a list of (original, mutated) pairs and the second is None.
MUTANTS = {
    "id_free_any_beat": (
        "if (m_axi_rlast) inflight[r_id] <= 1'b0;", "inflight[r_id] <= 1'b0;", "FAIL",
        "ID freed on any beat, not on RLAST: reused while its burst is still in flight"),
    "shared_beat_count": (
        "tab_beat[r_id] <= tab_beat[r_id] + 3'd1;", "tab_beat[0] <= tab_beat[0] + 3'd1;", "FAIL",
        "beat position kept for ID 0 only: interleaved beats of other IDs land in the wrong place"),
    "split_beat0": (
        "burst_beat0 = first_beats[2:0];", "burst_beat0 = 3'd0;", "FAIL",
        "second half of a 4 KB-split row written from beat 0 (overwrites the first half)"),
    "no_4k_split": (
        "burst_beats = (beats_room < 10'(beats_total)) ? beats_room[3:0] : beats_total;",
        "burst_beats = beats_total;", "FAIL",
        "rows never split at a 4 KB boundary"),
    "packed_rows": (
        "row_addr <= row_addr + 32'(stride_q);", "row_addr <= row_addr + 32'({beats_total, 3'b000});", "FAIL",
        "next row address ignores the stride (assumes packed rows)"),
    "ar_drop_early": (
        "if (m_axi_arvalid && m_axi_arready)\n        m_axi_arvalid <= 1'b0;",
        "if (m_axi_arvalid)\n        m_axi_arvalid <= 1'b0;", "FAIL",
        "ARVALID dropped after one cycle even without ARREADY"),
    "drain_early": (
        "if (!m_axi_arvalid && inflight == '0) begin", "if (!m_axi_arvalid) begin", "FAIL",
        "done before every burst in flight has returned"),
    "err_not_reported": (
        "err   <= err_seen;", "err   <= 1'b0;", "FAIL",
        "an RRESP error is not reported with done"),
    "issue_after_err": (
        [("if (err_seen || r_err) begin\n            state <= S_DRAIN;", "if (1'b0) begin\n            state <= S_DRAIN;"),
         ("!err_seen && !r_err && ", "")], None, "FAIL",
        "keeps issuing reads after an RRESP error"),
    # Safe changes: the proof must still pass.
    # Week 1 argued by hand that dropping !r_err from load_ar changes nothing (the S_ISSUE if/else
    # already blocks a load in the error cycle); the proof settles it.
    "safe_no_r_err_guard": (
        "!err_seen && !r_err && ", "!err_seen && ", "PASS",
        "(equivalent) load_ar without the same-cycle error guard", "prove"),
    "safe_three_ids": (
        "for (int i = MAX_OT - 1; i >= 0; i--)", "for (int i = MAX_OT - 2; i >= 0; i--)", "PASS",
        "(safe, slower) only IDs 0..2 are ever used", "prove"),
}

if __name__ == "__main__":
    mutlib.main(BLOCK, MUTANTS)
