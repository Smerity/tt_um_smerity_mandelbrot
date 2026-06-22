# Compares the RTL values in results.txt against a bit-exact reference for each
# (cx, cy, maxit) in points.txt. The reference mirrors the RTL iteration exactly
# (escape-first; arithmetic >> matches Verilog >>> for the signed cross term).
import sys

FRAC = 28


def mandel_ref(cx, cy, maxit):
    zr = zi = 0
    for it in range(maxit + 1):
        mag2 = ((zr * zr) + (zi * zi)) >> FRAC
        if mag2 > (4 << FRAC):
            return it
        if it == maxit:
            return 0
        zr2 = (zr * zr) >> FRAC
        zi2 = (zi * zi) >> FRAC
        cross = (zr * zi) >> FRAC
        zr, zi = zr2 - zi2 + cx, (cross << 1) + cy
    return 0


pts = [tuple(map(int, l.split())) for l in open("points.txt") if l.strip()]
vals = [int(l) for l in open("results.txt") if l.strip()]
assert len(pts) == len(vals), f"{len(pts)} points but {len(vals)} results"

bad = 0
for (cx, cy, m), v in zip(pts, vals):
    exp = mandel_ref(cx, cy, m)
    if v != exp:
        bad += 1
        if bad <= 15:
            print(f"  MISMATCH cx={cx} cy={cy} maxit={m}: rtl={v} ref={exp}")

print(f"{'PASS' if bad == 0 else 'FAIL'}: {len(pts)} points checked, {bad} mismatches")
sys.exit(1 if bad else 0)
