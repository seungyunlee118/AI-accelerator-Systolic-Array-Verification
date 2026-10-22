#!/usr/bin/env python3
"""Mutation check for the UVM tests: does each test catch the bugs it was written for?

Each mutant is one small, realistic RTL bug, put into a copy of rtl/. The copy is compiled and
the mutant's target tests run on it (seed 1). The mutant is "killed" if at least one of them
fails. A surviving mutant is a hole in the testbench (or an equivalent mutant: no observable
difference, which must be argued). Run on the server, inside sim/:

  python3 mutate.py                    # all mutants
  python3 mutate.py rd_no_drain        # some of them
  python3 mutate.py -j 8
"""
import argparse
import concurrent.futures as cf
import os
import shutil
import sys
import time

import regress

ROOT = os.path.dirname(regress.SIM)

# name: (rtl file, [(original text, mutated text), ...], [tests that must catch it], what)
MUTANTS = {
    # ---- configuration check (err_cfg_test)
    "cfg_reject_64": ("sa_ctrl.sv", [("(m_q > MAX_DIM)", "(m_q >= MAX_DIM)")],
                      ["err_cfg_test"], "M = 64 rejected as BAD_DIM (off by one)"),
    "cfg_no_k_check": ("sa_ctrl.sv", [("(k_q == 0) || (k_q > MAX_DIM);", "1'b0;")],
                       ["err_cfg_test"], "K is never checked"),
    "cfg_addr_wins": ("sa_ctrl.sv", [("err_code_q <= bad_dim ? 4'd1 : 4'd2;", "err_code_q <= bad_addr ? 4'd2 : 4'd1;")],
                      ["err_cfg_test"], "BAD_ADDR reported when both errors are present"),
    "cfg_no_cstride": ("sa_ctrl.sv", [("(c_str_q < 16'(c_min_stride));", "1'b0;")],
                       ["err_cfg_test"], "C_STRIDE < E*N is accepted"),
    # ---- bus errors (err_bus_test)
    "rd_issue_after_err": ("sa_dma_rd.sv", [("if (err_seen || r_err) begin\n            state <= S_DRAIN;",
                                             "if (1'b0) begin\n            state <= S_DRAIN;"),
                                            ("!err_seen && !r_err && ", "")],
                           ["err_bus_test"], "keeps issuing reads after an RRESP error"),
    "rd_no_drain": ("sa_dma_rd.sv", [("if (!m_axi_arvalid && inflight == '0) begin",
                                      "if (!m_axi_arvalid && (inflight == '0 || err_seen)) begin")],
                    ["err_bus_test"], "ends the job on a read error without draining reads in flight"),
    "wr_err_ignored": ("sa_ctrl.sv", [("if (wr_err) finish(4'd4);", "if (1'b0) finish(4'd4);")],
                       ["err_bus_test"], "write error ignored, job ends with DONE"),
    "err_cycles_zero": ("sa_ctrl.sv", [("cycles_q   <= cyc_cnt + 32'd1;", "cycles_q   <= (code == 4'd0) ? cyc_cnt + 32'd1 : '0;")],
                        ["err_bus_test"], "CYCLES not updated when a job ends with a bus error"),
    # ---- back-to-back and configuration while busy (b2b_jobs_test)
    "live_c_base": ("sa_ctrl.sv", [("wr_cmd_addr   = c_base_q + ", "wr_cmd_addr   = c_base + ")],
                    ["b2b_jobs_test"], "C address uses the live C_BASE register, not the value sampled at START"),
    # ---- reset (reset_midjob_test)
    "rst_keeps_cycles": ("sa_ctrl.sv", [("      err_code_q <= '0;\n      cycles_q   <= '0;", "      err_code_q <= '0;")],
                         ["reset_midjob_test"], "CYCLES not cleared by reset"),
    "rst_keeps_err_code": ("sa_ctrl.sv", [("      cyc_cnt    <= '0;\n      err_code_q <= '0;\n", "      cyc_cnt    <= '0;\n")],
                           ["reset_midjob_test"], "ERR_CODE not cleared by reset"),
    # FPGA habit: a power-up value instead of a reset. Power-on works, a later reset leaves
    # the IDs of bursts that were in flight marked busy forever.
    # (Xcelium rejects an initial value on an always_ff variable, *E,MULAXX, so the mutant
    # also turns the block into a plain always, as such FPGA code usually is.)
    "rst_keeps_ids": ("sa_dma_rd.sv", [("  logic [MAX_OT-1:0] inflight;", "  logic [MAX_OT-1:0] inflight = '0;"),
                                       ("      inflight      <= '0;\n", ""),
                                       ("  always_ff @(posedge clk or negedge rst_n) begin\n    if (!rst_n) begin\n      state         <= S_IDLE;",
                                        "  always @(posedge clk or negedge rst_n) begin\n    if (!rst_n) begin\n      state         <= S_IDLE;")],
                      ["reset_midjob_test"], "read ID table has a power-up value but is not cleared by reset"),
    # ---- DMA and output stage
    "wr_no_4k_split": ("sa_dma_wr.sv", [("burst_beats = (beats_room < 10'(beats_left)) ? beats_room[3:0] : beats_left;",
                                         "burst_beats = beats_left;")],
                       ["dma_4k_test"], "C write bursts not split at 4 KB"),
    "quant_shift0": ("sa_outq.sv", [("if (shift == 5'd0) r = p;", "if (1'b0) r = p;")],
                     ["gemm_quant_test"], "SHIFT = 0 goes through the rounding path"),
    "quant_neg_ties_away": ("sa_outq.sv", [("else               r = (p + (49'sd1 <<< (shift - 5'd1))) >>> shift;",
                                            "else               r = (p < 0) ? -((-p + (49'sd1 <<< (shift - 5'd1))) >>> shift)\n"
                                            "                                   : (p + (49'sd1 <<< (shift - 5'd1))) >>> shift;")],
                            ["gemm_quant_test"], "negative ties rounded away from zero instead of toward +infinity"),
    "quant_sat_128": ("sa_outq.sv", [("if      (r > 49'sd127)", "if      (r > 49'sd128)")],
                      ["gemm_quant_test"], "saturation off by one: 128 wraps to -128"),
}


def build_mutant(name, work):
    """Copy rtl/ with the mutation applied, and a filelist that points at it."""
    rtl_file, edits, _, _ = MUTANTS[name]
    d = os.path.join(work, name)
    shutil.rmtree(d, ignore_errors=True)
    shutil.copytree(os.path.join(ROOT, "rtl"), os.path.join(d, "rtl"))
    path = os.path.join(d, "rtl", rtl_file)
    src = open(path).read()
    for old, new in edits:
        if src.count(old) != 1:
            raise RuntimeError("%s: text found %d times in %s: %r" % (name, src.count(old), rtl_file, old))
        src = src.replace(old, new)
    open(path, "w").write(src)
    # filelist with absolute paths: RTL from the mutant copy, everything else from the repo
    fl = open(os.path.join(regress.SIM, "files_top.f")).read()
    fl = fl.replace("../rtl/", os.path.join(d, "rtl") + "/").replace("../tb/", os.path.join(ROOT, "tb") + "/")
    open(os.path.join(d, "files_top.f"), "w").write(fl)
    return d


def check(name, work):
    _, _, tests, what = MUTANTS[name]
    d = build_mutant(name, work)
    try:
        lib = regress.compile_tb("top", d, filelist=os.path.join(d, "files_top.f"), cwd=d)
    except RuntimeError as e:
        return name, "COMPILE", str(e), what
    for t in tests:
        r = regress.run_one(lib, t, 1, regress.TESTS[t][1], os.path.join(d, t), timeout=1800)
        if not r["passed"]:
            return name, "KILLED", "%s: %s" % (t, r["msg"]), what
    return name, "SURVIVED", "passed " + ", ".join(tests), what


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("names", nargs="*", help="mutants to run (default all)")
    ap.add_argument("-j", "--jobs", type=int, default=6)
    args = ap.parse_args()
    names = args.names or list(MUTANTS)
    work = os.path.join(regress.SIM, "mutants", time.strftime("%Y%m%d_%H%M%S"))
    os.makedirs(work)

    t0 = time.time()
    with cf.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        results = list(pool.map(lambda n: check(n, work), names))
    killed = 0
    for name, status, detail, what in results:
        killed += status == "KILLED"
        print("%-20s %-8s %s\n%22s%s" % (name, status, what, "", detail))
    print("\n%d/%d mutants killed (wall %.0f s), work dir %s" % (killed, len(names), time.time() - t0, work))
    sys.exit(0 if killed == len(names) else 1)


if __name__ == "__main__":
    main()
