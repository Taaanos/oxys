#!/usr/bin/env python3
"""P-06: compare the first and the last toggles of a `peaking-still` or `clipping-still` log.
Usage: scripts/toggle-step.py <log.tsv> [interval ...]   (default: every *-on and *-off interval)
Prints p50 and p95 of toggles 1 to 45 and 50 to 100, and the ratio of the p95 values."""
import sys

def p95(v):
    v = sorted(v)
    return v[int(0.95 * (len(v) - 1) + 0.5)]

def p50(v):
    v = sorted(v)
    return v[len(v) // 2]

rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1]) if l.count("\t") == 1]
names = sys.argv[2:] or sorted({r[0] for r in rows if r[0].endswith(("-on", "-off")) and r[0].split("-")[0] in ("peaking", "clipping")})
for name in names:
    v = [float(r[1]) for r in rows if r[0] == name]
    if len(v) < 100:
        continue
    a, b = v[:45], v[49:]
    print(f"{name:14} 1-45 p50 {p50(a):6.1f} p95 {p95(a):6.1f} | 50-100 p50 {p50(b):6.1f} p95 {p95(b):6.1f} | p95 ratio {p95(b) / p95(a):.2f}")
