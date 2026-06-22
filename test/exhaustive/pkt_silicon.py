# Test 4 (the real one): exercise the LITERAL chip top's packet receiver
# (param_valid/param_frame handshake) on silicon. For each view we send
# "0xC3 + 13-byte packet" to the FPGA wrapper, which drives those bytes into
# tt_um_smerity_mandelbrot's actual packet interface, captures the rendered
# frame, and dumps it. We bit-exact-check every pixel against the reference.
#   uv run --with pyserial python pkt_silicon.py [port]
import glob
import struct
import sys
import time

import serial

FRAC = 28
ONE = 1 << FRAC
BAUD = 115200
W, H = 64, 48


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


def read_exact(ser, n, deadline):
    b = bytearray()
    while len(b) < n:
        if time.time() > deadline:
            return None
        c = ser.read(n - len(b))
        if c:
            b += c
    return bytes(b)


def check(ser, name, cx_c, cy_c, span, maxit):
    step = q(span / W)
    cx0 = q(cx_c) - (W // 2) * step
    cy0 = q(cy_c) - (H // 2) * step
    pkt = b"\xC3" + struct.pack(">iii", cx0, cy0, step) + bytes([maxit & 0xFF])
    ser.reset_input_buffer()
    ser.write(pkt)

    dl = time.time() + 25
    # sync to 0xA5 0x5A
    win = bytearray()
    while True:
        if time.time() > dl:
            print(f"  {name:20s} maxit={maxit:<3} TIMEOUT (no dump)"); return 1
        c = ser.read(1)
        if not c:
            continue
        win += c; win = win[-2:]
        if win == b"\xA5\x5A":
            break
    hdr = read_exact(ser, 4, dl)
    rw, rh = int.from_bytes(hdr[0:2], "big"), int.from_bytes(hdr[2:4], "big")
    if (rw, rh) != (W, H):
        print(f"  {name:20s} maxit={maxit:<3} BAD HEADER {rw}x{rh}"); return 1
    data = read_exact(ser, W * H, dl)
    if data is None:
        print(f"  {name:20s} maxit={maxit:<3} TIMEOUT (short frame)"); return 1

    bad = sum(1 for i, v in enumerate(data)
              if v != mandel_ref(cx0 + (i % W) * step, cy0 + (i // W) * step, maxit))
    print(f"  {name:20s} maxit={maxit:<3} {len(data)} px -> {'OK' if bad == 0 else f'{bad} WRONG'}")
    return bad


def find_port():
    ports = sorted(glob.glob("/dev/cu.usbserial-*"))
    return ports[-1] if ports else None


VIEWS = [
    ("full set",        -0.5,   0.0,   3.0,   [1, 2, 30, 100, 253]),
    ("seahorse zoom",   -0.745, 0.113, 0.01,  [100, 250]),
    ("deep zoom",       -0.745, 0.113, 5e-4,  [200]),
    ("cardioid in-set", -0.2,   0.0,   0.6,   [250]),
    ("period-2 bulb",   -1.0,   0.0,   0.3,   [200]),
    ("all-escape",       1.4,   1.0,   0.5,   [50]),
    ("panned corner",   -1.8,   0.6,   0.4,   [100]),
    ("mini-mandelbrot", -1.75,  0.0,   0.05,  [200]),
    ("elephant valley",  0.3,   0.0,   0.05,  [200]),
]


def main():
    port = sys.argv[1] if len(sys.argv) > 1 else find_port()
    ser = serial.Serial(port, BAUD, timeout=1)
    print(f"packet-path sweep on {port} @ {BAUD}, frames {W}x{H}")
    total = frames = 0
    for name, cx, cy, span, maxits in VIEWS:
        for m in maxits:
            total += check(ser, name, cx, cy, span, m)
            frames += 1
    ser.close()
    print("-" * 50)
    print(f"{frames} views, {frames*W*H} pixels, {total} mismatches "
          f"-> {'PASS' if total == 0 else 'FAIL'}")
    sys.exit(1 if total else 0)


if __name__ == "__main__":
    main()
