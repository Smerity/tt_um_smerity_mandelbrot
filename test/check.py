"""Bit-exact checker for tb_selfcheck.v's pixels.txt dump.

Mirrors the RTL integer arithmetic exactly (escape-first), so every emitted
pixel must equal the reference. Also confirms the view-packet path committed (a
'P' pixel reaches the new view's left edge) and that the stream contains both
in-set and escaped pixels.
"""
import os
import sys

FRAC  = int(os.environ.get("FRAC", "28"))
MAXIT = int(os.environ.get("MAXIT", "100"))


def mandel_ref(cx, cy):
    zr = zi = 0
    for it in range(MAXIT + 1):
        mag2 = ((zr * zr) + (zi * zi)) >> FRAC
        if mag2 > (4 << FRAC):
            return it
        if it == MAXIT:
            return 0
        zr2 = (zr * zr) >> FRAC
        zi2 = (zi * zi) >> FRAC
        cross = (zr * zi) >> FRAC
        zr, zi = zr2 - zi2 + cx, (cross << 1) + cy
    return 0


def main():
    total = mism = inset = esc = p_newview = 0
    first_mismatches = []
    near_left = -(int(2.4 * (1 << FRAC)))          # cx <= -2.4  => new view committed

    with open("pixels.txt") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            mode, scx, scy, sval = line.split()
            cx, cy, val = int(scx), int(scy), int(sval)
            total += 1
            exp = mandel_ref(cx, cy)
            if val != exp:
                mism += 1
                if len(first_mismatches) < 6:
                    first_mismatches.append((mode, cx, cy, val, exp))
            if val == 0:
                inset += 1
            else:
                esc += 1
            if mode == "P" and cx <= near_left:
                p_newview += 1

    print(f"FRAC={FRAC} MAXIT={MAXIT}")
    print(f"pixels checked : {total}")
    print(f"  bit-exact    : {total - mism}")
    print(f"  mismatches   : {mism}")
    print(f"  in-set (=0)  : {inset}")
    print(f"  escaped      : {esc}")
    print(f"  'P' new-view : {p_newview}")

    ok = True
    if total == 0:
        print("FAIL: no pixels captured"); ok = False
    if mism:
        print(f"FAIL: {mism} mismatches, first few (mode,cx,cy,got,exp): {first_mismatches}"); ok = False
    if inset == 0 or esc == 0:
        print("FAIL: expected both in-set and escaped pixels"); ok = False
    if p_newview == 0:
        print("FAIL: view packet never committed (no 'P' pixel at the new left edge)"); ok = False

    print("RESULT:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
