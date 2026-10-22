#!/usr/bin/env python3
"""Formal mutation check for the CSR proof.

Each mutant is one small, realistic bug put into a copy of rtl/sa_csr.sv. The proof must FAIL on
every bug mutant (the bug is "killed", with a counterexample trace) and must still PASS on the
"safe" mutants, which change the RTL without breaking the spec. The runner is ../mutlib.py.

  source ~/oss-cad-suite/environment
  python3 mutants.py              # all mutants
  python3 mutants.py w1c_clear_wins irq_no_enable
"""
import sys

sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent.parent))
import mutlib  # noqa: E402

HERE = mutlib.block_dir(__file__)
BLOCK = {"dir": HERE, "rtl": (HERE / "../../rtl/sa_csr.sv").resolve(), "props": HERE / "sa_csr_props.svh",
         "sby": HERE / "sa_csr.sby", "gtkw": "csr.gtkw", "task": "prove"}

# name: (original text, mutated text, expected proof result, what the bug is)
MUTANTS = {
    "strb_ignored": (
        "lm = lane_mask(strb) & mask;", "lm = mask;", "FAIL",
        "write strobes ignored: every byte lane is written"),
    "decode_5_2": (
        "aw_addr_q <= {s_axil_awaddr[7:2], 2'b00};", "aw_addr_q <= {2'b00, s_axil_awaddr[5:2], 2'b00};", "FAIL",
        "write decode ignores address bits 7:6 (0x40 aliases to CTRL)"),
    "unmapped_okay": (
        "s_axil_bresp  <= wr_mapped ? 2'b00 : 2'b10;", "s_axil_bresp  <= 2'b00;", "FAIL",
        "write to an unmapped offset answers OKAY instead of SLVERR"),
    "w1c_clear_wins": (
        "r_irq_st <= (r_irq_st & ~irq_clr) | {30'b0, evt_err, evt_done};",
        "r_irq_st <= (r_irq_st | {30'b0, evt_err, evt_done}) & ~irq_clr;", "FAIL",
        "same-cycle W1C clear wins over a new event (event lost)"),
    "w1c_ignores_strb": (
        "(w_data_q & lane_mask(w_strb_q) & M_IRQ)", "(w_data_q & M_IRQ)", "FAIL",
        "W1C clears flags even when byte lane 0 is not strobed"),
    "irq_no_enable": (
        "assign irq      = |(r_irq_st[1:0] & r_irq_en[1:0]);", "assign irq      = |r_irq_st[1:0];", "FAIL",
        "irq ignores IRQ_EN"),
    "start_no_lane0": (
        "w_strb_q[0] && w_data_q[0];", "w_data_q[0];", "FAIL",
        "START fires even when byte lane 0 is not strobed"),
    "dims_reserved_rw": (
        "M_DIMS = 32'h007F_7F7F;", "M_DIMS = 32'h00FF_FFFF;", "FAIL",
        "reserved DIMS bits become writable"),
    "b_not_held": (
        "end else if (s_axil_bvalid && s_axil_bready) begin", "end else if (s_axil_bvalid) begin", "FAIL",
        "BVALID drops after one cycle even if BREADY is low"),
    "rd_unaligned": (
        "case ({s_axil_araddr[7:2], 2'b00})", "case (s_axil_araddr[7:0])", "FAIL",
        "unaligned read address (low bits != 0) answers SLVERR"),
    # Safe change: accept the next read in the same cycle the current R is taken. Legal AXI4-Lite,
    # one cycle faster for back-to-back reads; the proof shows it still meets the spec.
    "safe_rd_pipelined": (
        "assign s_axil_arready = !s_axil_rvalid;", "assign s_axil_arready = !s_axil_rvalid || s_axil_rready;", "PASS",
        "(safe) accept AR while the previous R is being taken"),
}



if __name__ == "__main__":
    mutlib.main(BLOCK, MUTANTS)
