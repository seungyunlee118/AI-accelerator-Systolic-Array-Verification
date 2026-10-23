#!/usr/bin/env python3
"""Regression runner for the SA-GEMM UVM tests (Cadence Xcelium).

Each testbench is compiled once; then every test x seed runs from that snapshot, several at a
time, each in its own directory. Run on the server, inside sim/:

  python3 regress.py                         # every test, seeds 1..4 (daily regression)
  python3 regress.py --seeds 20              # sign-off depth: seeds 1..20
  python3 regress.py -t err_bus_test -t gemm_quant_test --seeds 3
  python3 regress.py --seed-list 7 42        # exact seeds
  python3 regress.py -j 8                    # simulations at the same time (default 6)
  python3 regress.py --array 8               # full-chip tests only on the 8x8 build

Full-chip tests run on every PE array size given by --array (default 4 and 8; files_top.f and
files_top8.f); 8x8 runs are named <test>@8x8.

Output goes to regress/<date_time>/: one log per run, summary.txt, results.xml (JUnit XML,
the format CI servers read), and coverage.txt: functional coverage merged over the passing runs
(covmerge.py, with the waivers in cov_waivers.txt). The exit code is 0 only if every run passed.
A run passes when its log has "TEST PASSED" and no Xcelium *E/*F message.
"""
import argparse
import concurrent.futures as cf
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

import covmerge

SIM = os.path.dirname(os.path.abspath(__file__))

# test: (testbench, extra plusargs). Testbench "x" compiles files_x.f.
TESTS = {
    "csr_reset_test":        ("csr", []),
    "csr_rw_test":           ("csr", []),
    "csr_access_test":       ("csr", []),
    "csr_irq_test":          ("csr", []),
    "gemm_smoke_test":       ("top", []),
    "gemm_rand_test":        ("top", []),
    "gemm_dim_test":         ("top", []),
    "gemm_edge_test":        ("top", []),
    "gemm_stride_test":      ("top", []),
    "gemm_quant_test":       ("top", []),
    "dma_ooo_test":          ("top", []),
    "dma_backpressure_test": ("top", []),
    "dma_4k_test":           ("top", []),
    "b2b_jobs_test":         ("top", []),
    "err_cfg_test":          ("top", []),
    "err_bus_test":          ("top", []),
    "reset_midjob_test":     ("top", []),
}

XRUN_ERR = re.compile(r"^\S+: \*[EF],(?!IMPDLL).*$", re.M)   # IMPDLL: harmless here (no DPI-C)


def compile_tb(tb, out, filelist=None, cwd=SIM):
    """Compile and elaborate one testbench into out/build_<tb>. Returns the library path.
    Paths inside the filelist are relative to cwd (sim/ for the normal filelists)."""
    lib = os.path.join(out, "build_" + tb, "xcelium.d")
    log = os.path.join(out, "build_" + tb + ".log")
    os.makedirs(os.path.dirname(lib), exist_ok=True)       # xrun does not create parent dirs
    cmd = ["xrun", "-f", os.path.join(SIM, "xrun.args"), "-f", filelist or "files_%s.f" % tb,
           "-elaborate", "-xmlibdirname", lib, "-l", log]
    rc = subprocess.call(cmd, cwd=cwd, stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    text = open(log, errors="replace").read() if os.path.exists(log) else ""
    if rc != 0 or XRUN_ERR.search(text):
        first = XRUN_ERR.search(text)
        raise RuntimeError("compile of %s failed (%s); see %s" %
                           (tb, first.group(0) if first else "rc=%d" % rc, log))
    return lib


def run_one(lib, test, seed, plusargs, rundir, timeout=3600):
    """Simulate one test/seed from a compiled snapshot. Returns a result dict."""
    os.makedirs(rundir, exist_ok=True)
    log = os.path.join(rundir, "run.log")
    cmd = ["xrun", "-64bit", "-R", "-xmlibdirname", lib, "-nocopyright", "-svseed", str(seed),
           "+UVM_TESTNAME=" + test, "+UVM_VERBOSITY=UVM_LOW", "+COV_DUMP=cov.txt", "-l", log] + plusargs
    t0 = time.time()
    try:
        subprocess.call(cmd, cwd=rundir, stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT,
                        timeout=timeout)
        hung = False
    except subprocess.TimeoutExpired:
        hung = True
    res = {"test": test, "seed": seed, "log": log, "secs": time.time() - t0}
    res.update(parse_log(log, hung))
    return res


def parse_log(log, hung=False):
    text = open(log, errors="replace").read() if os.path.exists(log) else ""
    passed = "TEST PASSED" in text and not XRUN_ERR.search(text) and not hung
    m = re.search(r"UVM_ERROR :\s+(\d+)", text)
    jobs = re.search(r"\[SB\] checked (\d+) good jobs \((\d+) elements\) and (\d+) error jobs", text)
    simt = re.search(r"Simulation complete via \S+ at time (\d+) NS", text)
    first = (re.search(r"^(UVM_(ERROR|FATAL) .*)$", text, re.M) or XRUN_ERR.search(text))
    msg = ""
    if not passed:
        if hung:
            msg = "wall-clock timeout"
        elif first:
            msg = re.sub(r"\s+", " ", first.group(0))[:160]
        else:
            msg = "no TEST PASSED line"
    return {"passed": passed, "errors": int(m.group(1)) if m else -1, "msg": msg,
            "jobs": "%s+%s" % (jobs.group(1), jobs.group(3)) if jobs else "",
            "sim_us": int(simt.group(1)) / 1000.0 if simt else 0.0}


def write_junit(results, path):
    suite = ET.Element("testsuite", name="sa_gemm", tests=str(len(results)),
                       failures=str(sum(not r["passed"] for r in results)))
    for r in results:
        case = ET.SubElement(suite, "testcase", classname=r["tb"], name="%s.seed%d" % (r["test"], r["seed"]),
                             time="%.1f" % r["secs"])
        if not r["passed"]:
            ET.SubElement(case, "failure", message=r["msg"]).text = r["log"]
    ET.ElementTree(suite).write(path, encoding="utf-8", xml_declaration=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-t", "--test", action="append", help="test to run (repeatable); default all")
    ap.add_argument("--seeds", type=int, default=4, help="run seeds 1..N (default 4)")
    ap.add_argument("--seed-list", type=int, nargs="+", help="exact seeds instead of 1..N")
    ap.add_argument("-j", "--jobs", type=int, default=6, help="parallel simulations (default 6)")
    ap.add_argument("-o", "--out", help="output directory (default regress/<date_time>)")
    ap.add_argument("--array", default="4,8", help="PE array sizes for full-chip tests (default 4,8)")
    args = ap.parse_args()

    tests = args.test or list(TESTS)
    for t in tests:
        if t not in TESTS:
            sys.exit("unknown test %s; known: %s" % (t, ", ".join(TESTS)))
    seeds = args.seed_list or list(range(1, args.seeds + 1))
    out = os.path.abspath(args.out or os.path.join(SIM, "regress", time.strftime("%Y%m%d_%H%M%S")))
    os.makedirs(out, exist_ok=True)

    # (label, test, build): full-chip tests once per array size, the 8x8 build is "top8"
    variants = []
    for t in tests:
        if TESTS[t][0] != "top":
            variants.append((t, t, TESTS[t][0]))
            continue
        for n in [int(x) for x in args.array.split(",")]:
            variants.append((t if n == 4 else "%s@%dx%d" % (t, n, n), t, "top" if n == 4 else "top%d" % n))
    labels = [v[0] for v in variants]

    t0 = time.time()
    libs = {}
    for tb in sorted({v[2] for v in variants}):
        print("compiling %s ..." % tb, flush=True)
        libs[tb] = compile_tb(tb, out)

    runs = [(v, s) for v in variants for s in seeds]
    print("running %d simulations, %d at a time -> %s" % (len(runs), args.jobs, out), flush=True)
    results = []

    def run_variant(v, s):
        label, test, tb = v
        r = run_one(libs[tb], test, s, TESTS[test][1], os.path.join(out, "runs", "%s_%d" % (label, s)))
        r["test"], r["tb"] = label, tb
        return r

    with cf.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futs = [pool.submit(run_variant, v, s) for v, s in runs]
        for f in cf.as_completed(futs):
            r = f.result()
            results.append(r)
            print("  %-4s %-22s seed %-3d %5.0fs" % ("PASS" if r["passed"] else "FAIL", r["test"], r["seed"], r["secs"]),
                  flush=True)

    results.sort(key=lambda r: (labels.index(r["test"]), r["seed"]))
    lines = ["%-28s %5s  %-6s %8s %10s %7s  %s" % ("test", "seed", "result", "jobs", "sim (us)", "wall", "first error")]
    for r in results:
        lines.append("%-28s %5d  %-6s %8s %10.0f %6.0fs  %s" % (r["test"], r["seed"], "PASS" if r["passed"] else "FAIL",
                                                             r["jobs"], r["sim_us"], r["secs"], r["msg"]))
    n_fail = sum(not r["passed"] for r in results)
    lines.append("")
    for t in labels:
        rs = [r for r in results if r["test"] == t]
        lines.append("%-28s %d/%d passed" % (t, sum(r["passed"] for r in rs), len(rs)))
    lines.append("")
    lines.append("%d runs: %d passed, %d failed (wall %.0f s)" % (len(results), len(results) - n_fail, n_fail,
                                                                 time.time() - t0))
    if n_fail:
        lines.append("reproduce a failure: make TB=<csr|top|top8> TEST=<test> SEED=<seed>   (add GUI=1 or WAVE=1 to debug)")
    report = "\n".join(lines)
    print("\n" + report)
    open(os.path.join(out, "summary.txt"), "w").write(report + "\n")
    write_junit(results, os.path.join(out, "results.xml"))

    # functional coverage of the passing runs only
    cov_files = {}
    for r in results:
        path = os.path.join(os.path.dirname(r["log"]), "cov.txt")
        if r["passed"] and os.path.exists(path):
            cov_files.setdefault(r["test"], []).append(path)
    if cov_files:
        cov_report, total = covmerge.merge(cov_files, covmerge.read_waivers(os.path.join(SIM, "cov_waivers.txt")))
        open(os.path.join(out, "coverage.txt"), "w").write(cov_report + "\n")
        print("\nfunctional coverage %.1f%% (details: %s)" % (total, os.path.join(out, "coverage.txt")))
    sys.exit(1 if n_fail else 0)


if __name__ == "__main__":
    main()
