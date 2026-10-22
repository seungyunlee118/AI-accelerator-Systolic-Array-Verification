"""Shared runner for the formal mutation checks (formal/<block>/mutants.py).

A mutant is one small, realistic bug put into a copy of the block's RTL. Each one runs one
SymbiYosys task on the copy and must give the expected result: FAIL (the bug is killed, with a
counterexample trace) for a bug, PASS for a safe change that keeps the spec.
"""
import concurrent.futures as cf
import pathlib
import re
import shutil
import subprocess
import sys


def run_one(block, name, mutant):
    """block: dict(dir, rtl, props, sby, gtkw). mutant: (orig, new, expect, what[, task])."""
    orig, new, expect, what = mutant[:4]
    task = mutant[4] if len(mutant) > 4 else block["task"]
    here, rtl, props = block["dir"], block["rtl"], block["props"]
    src = rtl.read_text()
    edits = orig if isinstance(orig, list) else [(orig, new)]
    for o, n in edits:
        if src.count(o) != 1:
            return name, expect, "NO-MATCH", "original text found %d times: %r" % (src.count(o), o), what
        src = src.replace(o, n)

    d = here / "mutants_work" / name
    shutil.rmtree(d, ignore_errors=True)
    d.mkdir(parents=True)
    (d / rtl.name).write_text(src)
    shutil.copy(props, d / props.name)
    (d / "m.sby").write_text(block["sby"].read_text().replace("../../rtl/" + rtl.name, rtl.name))

    subprocess.run(["sby", "-f", "m.sby", task], cwd=d, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    log = (d / ("m_" + task) / "logfile.txt").read_text()
    status = re.search(r"DONE \((\w+)", log).group(1)

    detail = ""
    m = re.search(r"failed assertion \S+ at %s:(\d+)\S* step (\d+)" % re.escape(props.name), log)
    if m:
        line = props.read_text().splitlines()[int(m.group(1)) - 1].strip()
        detail = "props:%s, cycle %s after reset:  %s" % (m.group(1), m.group(2), line)
        trace = re.search(r"counterexample trace(?: \[basecase\])?: (\S+)", log)
        if trace:
            detail += "\n%22sview:  gtkwave %s/%s %s 2>/dev/null" % ("", d.relative_to(here), trace.group(1),
                                                                     block.get("gtkw", ""))
    return name, expect, status, detail, "%s [%s]" % (what, task)


def main(block, mutants, jobs=4):
    names = sys.argv[1:] or list(mutants)
    with cf.ThreadPoolExecutor(max_workers=jobs) as pool:
        results = list(pool.map(lambda n: run_one(block, n, mutants[n]), names))
    bad = 0
    for name, expect, status, detail, what in results:
        ok = status == expect
        bad += not ok
        verdict = ("killed" if status == "FAIL" else "proved") if ok else "UNEXPECTED (wanted %s)" % expect
        print("%-20s  %-7s  %-8s  %s" % (name, status, verdict, what))
        if detail:
            print("%22s%s" % ("", detail))
    print("\n%d/%d mutants behaved as expected" % (len(names) - bad, len(names)))
    sys.exit(1 if bad else 0)


def block_dir(file):
    return pathlib.Path(file).resolve().parent
