# Checks the frame captured by tb_ramtest.v (sim_rx.txt) against the bit-exact
# integer reference. Pure stdlib:  uv run python check_ramsim.py [sim_rx.txt]

import sys

FRAC = 28
MAXIT = 100


def mandel_ref(cx, cy):
    """Bit-exact mirror of the RTL iteration (escape-first)."""
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


def default_view():
    step = (7 << FRAC) // 640
    cx0 = -((1 << (FRAC - 1)) + 160 * step)
    cy0 = -(120 * step)
    return cx0, cy0, step


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "sim_rx.txt"
    with open(path) as f:
        w, h, cycles = (int(x) for x in f.readline().split())
        pix = [int(line) for line in f if line.strip()]

    assert len(pix) == w * h, f"got {len(pix)} pixels, expected {w*h}"
    cx0, cy0, step = default_view()
    bad = 0
    for i, v in enumerate(pix):
        x, y = i % w, i // w
        exp = mandel_ref(cx0 + x * step, cy0 + y * step)
        if v != exp:
            bad += 1
            if bad <= 8:
                print(f"  MISMATCH pixel {i} (x={x},y={y}): got {v}, expected {exp}")

    if bad:
        print(f"FAIL: {bad}/{len(pix)} mismatches")
        sys.exit(1)
    print(f"PASS: {w}x{h} = {len(pix)} pixels bit-exact; frame = {cycles} cycles "
          f"({cycles/(w*h):.1f} cyc/pixel)")


if __name__ == "__main__":
    main()
