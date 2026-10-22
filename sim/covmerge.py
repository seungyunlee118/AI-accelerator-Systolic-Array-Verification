#!/usr/bin/env python3
"""Merge functional coverage over the runs of a regression (the lab server has no IMC).

Every run started with +COV_DUMP=cov.txt writes one "<group> <item> <bin> <hits>" line per bin
(tb/cov/sa_cov_db.svh). This script adds up the files of the passing runs:

  python3 covmerge.py regress/<date_time>                 # every runs/*/cov.txt below it
  python3 covmerge.py regress/<date_time> --waivers cov_waivers.txt

It prints coverage per group and per coverpoint/cross, lists the holes (bins no run hit), and
for each test how many bins only that test hits (what the regression would lose without it).
Coverage of an item = bins hit / bins not waived; of a group = mean over its items (the same
rule SystemVerilog uses for a covergroup); total = mean over the groups.
regress.py calls merge() itself after every regression.
"""
import argparse
import collections
import glob
import os
import re

GROUPS = {
    "CG-01":  "CSR accesses",
    "CG-01r": "CSR W1C set-vs-clear race",
    "CG-02":  "job configuration",
    "CG-03":  "output stage",
    "CG-04":  "DMA reads",
    "CG-05":  "DMA writes",
    "CG-06":  "errors",
    "CG-07":  "job flow",
    "CG-08":  "reset",
    "CG-09":  "array size",
}


def read_waivers(path):
    """'<group> <item> <bin>  # reason' per line -> {(group, item, bin): reason}"""
    waived = {}
    if path and os.path.exists(path):
        for line in open(path):
            body, _, reason = line.partition("#")
            f = body.split()
            if len(f) == 3:
                waived[tuple(f)] = reason.strip()
    return waived


def merge(cov_files, waivers=None):
    """cov_files: {test_name: [paths]}. Returns (report text, total percent)."""
    waivers = waivers or {}
    hits = collections.OrderedDict()           # (group, item, bin) -> hits over all runs
    by_test = collections.defaultdict(set)      # test -> bins it hit
    for test, paths in cov_files.items():
        for path in paths:
            for line in open(path):
                f = line.split()
                if len(f) != 4:
                    continue
                key, n = tuple(f[:3]), int(f[3])
                hits[key] = hits.get(key, 0) + n
                if n:
                    by_test[test].add(key)

    items = collections.OrderedDict()            # (group, item) -> [bins]
    for key in hits:
        items.setdefault(key[:2], []).append(key)

    lines, holes, group_pct = [], [], collections.OrderedDict()
    for grp in sorted({g for g, _ in items}, key=lambda g: (list(GROUPS).index(g) if g in GROUPS else 99, g)):
        rows = []
        for (g, item), keys in items.items():
            if g != grp:
                continue
            live = [k for k in keys if k not in waivers]
            hit = [k for k in live if hits[k]]
            pct = 100.0 * len(hit) / len(live) if live else 100.0
            rows.append((item, len(hit), len(live), pct))
            holes += [k for k in live if not hits[k]]
        group_pct[grp] = sum(r[3] for r in rows) / len(rows)
        lines.append("%-7s %-28s %6.1f%%" % (grp, GROUPS.get(grp, ""), group_pct[grp]))
        for item, h, n, pct in rows:
            lines.append("          %-26s %4d/%-4d %6.1f%%" % (item, h, n, pct))
    total = sum(group_pct.values()) / len(group_pct) if group_pct else 0.0

    out = ["Functional coverage (%d runs, %d bins, %d waived)" %
           (sum(len(p) for p in cov_files.values()), len(hits), sum(1 for k in hits if k in waivers)), ""]
    out += lines
    out += ["", "TOTAL %.1f%%" % total, ""]
    out.append("Holes (%d):" % len(holes) if holes else "Holes: none")
    out += ["  %s %s %s" % k for k in holes]
    waived_here = [k for k in hits if k in waivers]
    if waived_here:
        out += ["", "Waived (%d):" % len(waived_here)]
        out += ["  %s %s %s   # %s" % (k + (waivers[k],)) for k in waived_here]
    out += ["", "Bins only this test hits (losing the test loses them):"]
    for test in sorted(by_test, key=lambda t: -len(by_test[t] - set().union(*[by_test[o] for o in by_test if o != t]))):
        others = set().union(*[by_test[o] for o in by_test if o != test])
        out.append("  %-22s %4d  (hits %d bins)" % (test, len(by_test[test] - others), len(by_test[test])))
    return "\n".join(out), total


def find_cov_files(root):
    files = collections.defaultdict(list)
    for path in sorted(glob.glob(os.path.join(root, "runs", "*", "cov.txt"))):
        run = os.path.basename(os.path.dirname(path))
        files[re.sub(r"_\d+$", "", run)].append(path)
    return files


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("regress_dir")
    ap.add_argument("--waivers", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "cov_waivers.txt"))
    args = ap.parse_args()
    report, _ = merge(find_cov_files(args.regress_dir), read_waivers(args.waivers))
    print(report)
    open(os.path.join(args.regress_dir, "coverage.txt"), "w").write(report + "\n")


if __name__ == "__main__":
    main()
