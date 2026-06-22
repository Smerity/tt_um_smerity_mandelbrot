# Generate a broad (cx, cy, maxit) sweep in Q4.28 integer coords for the core
# math test. Stays within |c| <~ 2.5 so the design never overflows Q4.28 (the
# escape-at-|z|>2 rule caps the next z at ~6.5 < 8), so a full-precision Python
# reference matches the RTL bit-for-bit. Categories: grid, escape boundary,
# deep zoom, in-set interiors, and every maxit edge.
import random

random.seed(20260621)
FRAC = 28
ONE = 1 << FRAC
HI, LO = (1 << 31) - 1, -(1 << 31)


def q(v):
    return max(LO, min(HI, int(round(v * ONE))))


pts = []
def add(cx, cy, m): pts.append((q(cx), q(cy), m))

# 1. grid over the set + margin (whole Mandelbrot set is in [-2.5,1]x[-1.5,1.5])
GW, GH = 56, 44
for j in range(GH):
    cy = -1.6 + 3.2 * j / (GH - 1)
    for i in range(GW):
        cx = -2.3 + 3.3 * i / (GW - 1)
        add(cx, cy, 64)

# 2. escape-boundary fine points (just inside/outside key features)
for cxb in [-0.75, 0.25, -1.25, -0.125, 0.0]:
    for d in [-3e-5, -1e-5, 0.0, 1e-5, 3e-5]:
        for cy in [0.0, 0.5, 0.74]:
            add(cxb + d, cy, 200)

# 3. deep-zoom cluster near the seahorse valley (sub-microscale spacing -> low bits)
bx, by = -0.745428, 0.113009
for di in range(-12, 13):
    for dj in range(-12, 13):
        add(bx + di * 5e-7, by + dj * 5e-7, 120)

# 4. in-set interiors x every maxit edge
for (cx, cy) in [(-0.5, 0), (0, 0), (0.25, 0), (-1.0, 0), (-0.12, 0.74), (0.28, 0.008)]:
    for m in [1, 2, 3, 4, 50, 100, 200, 250, 253]:
        add(cx, cy, m)

# 5. maxit edges on fast-escaping points
for (cx, cy) in [(1.0, 1.0), (-2.0, 1.2), (0.6, 0.6), (-1.8, 0.0)]:
    for m in [0, 1, 2, 3, 253]:
        add(cx, cy, m)

# 6. random, in-range
for _ in range(2500):
    cx = random.uniform(-2.4, 1.2)
    cy = random.uniform(-1.6, 1.6)
    m = random.choice([1, 2, 3, 8, 30, 64, 150, 250, 253])
    add(cx, cy, m)

with open("points.txt", "w") as f:
    f.write("".join(f"{a} {b} {c}\n" for a, b, c in pts))
print(f"{len(pts)} points")
