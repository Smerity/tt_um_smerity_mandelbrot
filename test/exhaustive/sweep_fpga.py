# Test 3: full-chain view x maxit sweep on real silicon. Sends view packets to the
# viewer FPGA (DDA + packet receiver + stream + pipelined core), captures each
# streamed frame, and bit-exact-checks every pixel against the integer reference.
#   uv run --with pyserial python sweep_fpga.py [port]
#
# Views are kept within |c| <~ 2.5 so the design never overflows Q4.28 and the
# full-precision reference matches the RTL bit-for-bit.
import glob
import struct
import sys
import time

import serial

FRAC = 28
ONE = 1 << FRAC
BAUD = 1_000_000
HDR = 0xC3
W, H = 48, 36                 # small frames so the sweep is quick


def q(v):
    return max(-(1 << 31), min((1 << 31) - 1, int(round(v * ONE))))


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


def send_view(ser, cx0, cy0, step, maxit):
    pkt = (bytes([HDR]) + struct.pack(">iii", cx0, cy0, step)
           + bytes([maxit & 0xFF]) + struct.pack(">HH", W, H))
    ser.reset_input_buffer()
    ser.write(pkt)


def capture(ser, deadline):
    while True:                                  # sync to a fresh frame
        if time.time() > deadline:
            return None
        b = ser.read(1)
        if b and b[0] == 0xFF:
            break
    pix = []
    while len(pix) < W * H:
        if time.time() > deadline:
            return None
        b = ser.read(1)
        if not b:
            continue
        v = b[0]
        if v == 0xFF:
            pix = []                             # unexpected restart
        elif v != 0xFE:
            pix.append(v)
    return pix


def check(ser, name, cx_c, cy_c, span, maxit):
    step = q(span / W)
    cx0 = q(cx_c) - (W // 2) * step
    cy0 = q(cy_c) - (H // 2) * step
    send_view(ser, cx0, cy0, step, maxit)
    dl = time.time() + 20
    capture(ser, dl)                             # discard one (possibly torn) frame
    pix = capture(ser, dl)                        # the clean new-view frame
    if pix is None:
        print(f"  {name:22s} maxit={maxit:<3}  TIMEOUT")
        return 1
    bad = 0
    for i, v in enumerate(pix):
        x, y = i % W, i // W
        if v != mandel_ref(cx0 + x * step, cy0 + y * step, maxit):
            bad += 1
    tag = "OK" if bad == 0 else f"{bad} WRONG"
    print(f"  {name:22s} maxit={maxit:<3}  {len(pix)} px  -> {tag}")
    return bad


def find_port():
    ports = sorted(glob.glob("/dev/cu.usbserial-*"))
    return ports[-1] if ports else None


# (name, cx_center, cy_center, span, [maxits]) — all within |c| <~ 2.5
VIEWS = [
    ("full set",        -0.5,   0.0,   3.0,   [1, 2, 30, 100, 253]),
    ("seahorse zoom",   -0.745, 0.113, 0.01,  [100, 250]),
    ("deep zoom",       -0.745, 0.113, 5e-4,  [200]),
    ("cardioid in-set", -0.2,   0.0,   0.6,   [100, 250]),
    ("period-2 bulb",   -1.0,   0.0,   0.3,   [200]),
    ("all-escape",       1.4,   1.0,   0.5,   [50]),
    ("panned corner",   -1.8,   0.6,   0.4,   [100]),
    ("mini-mandelbrot", -1.75,  0.0,   0.05,  [200]),
    ("elephant valley",  0.3,   0.0,   0.05,  [200]),
]


def main():
    port = sys.argv[1] if len(sys.argv) > 1 else find_port()
    ser = serial.Serial(port, BAUD, timeout=1)
    print(f"sweep on {port} @ {BAUD}, frames {W}x{H}")
    total = 0
    frames = 0
    for name, cx, cy, span, maxits in VIEWS:
        for m in maxits:
            total += check(ser, name, cx, cy, span, m)
            frames += 1
    ser.close()
    print("-" * 50)
    print(f"{frames} frames, {frames*W*H} pixels checked, {total} mismatches "
          f"-> {'PASS' if total == 0 else 'FAIL'}")
    sys.exit(1 if total else 0)


if __name__ == "__main__":
    main()
