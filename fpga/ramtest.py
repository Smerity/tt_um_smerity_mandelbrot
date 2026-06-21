# Host receiver for ice_ramtest.v: reads one captured frame, checks every pixel
# against the bit-exact reference, and reports the TRUE frame rate (the FPGA fills
# on-chip RAM at full clock with no UART backpressure, so the measured cycle count
# is the real render time, not the link-limited one).
#
#   uv run --with pyserial python ramtest.py [port]
#
# Wire format (see ice_ramtest.v):
#   0xA5 0x5A  W[u16]  H[u16]  cycles[u32]  W*H pixel bytes   (all big-endian)

import glob
import sys
import time

import serial

FRAC = 28
MAXIT = 100
BAUD = 115200
FPGA_HZ = 12_000_000        # iCEBreaker clock
CHIP_HZ = 5_000_000         # GF180 submission clock (info.yaml)


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


def default_view():
    step = (7 << FRAC) // 640
    cx0 = -((1 << (FRAC - 1)) + 160 * step)
    cy0 = -(120 * step)
    return cx0, cy0, step


def find_port():
    ports = sorted(glob.glob("/dev/cu.usbserial-*"))
    if not ports:
        sys.exit("no /dev/cu.usbserial-* found — is the board plugged in?")
    return ports[-1]          # FT2232 channel B (UART) is the higher interface


def read_exact(ser, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = ser.read(n - len(buf))
        if chunk:
            buf += chunk
    return bytes(buf)


def sync_preamble(ser):
    # slide until we see 0xA5 0x5A
    window = bytearray()
    while True:
        b = ser.read(1)
        if not b:
            continue
        window += b
        if len(window) > 2:
            window = window[-2:]
        if window == b"\xA5\x5A":
            return


def main():
    port = sys.argv[1] if len(sys.argv) > 1 else find_port()
    ser = serial.Serial(port, BAUD, timeout=1)
    print(f"listening on {port} @ {BAUD} — waiting for a captured frame...")

    sync_preamble(ser)
    hdr = read_exact(ser, 8)
    w = int.from_bytes(hdr[0:2], "big")
    h = int.from_bytes(hdr[2:4], "big")
    cycles = int.from_bytes(hdr[4:8], "big")
    npix = w * h
    if not (1 <= w <= 4096 and 1 <= h <= 4096):
        sys.exit(f"implausible header W={w} H={h} — re-run to resync")

    print(f"frame {w}x{h} = {npix} px, measured {cycles} clocks; receiving...")
    t0 = time.time()
    data = read_exact(ser, npix)
    rx_dt = time.time() - t0
    ser.close()

    # bit-exact check
    cx0, cy0, step = default_view()
    bad = 0
    for i, v in enumerate(data):
        x, y = i % w, i // w
        exp = mandel_ref(cx0 + x * step, cy0 + y * step)
        if v != exp:
            bad += 1
            if bad <= 8:
                print(f"  MISMATCH px {i} (x={x},y={y}): got {v}, expected {exp}")

    # timing
    cyc_per_px = cycles / npix
    fps_fpga = FPGA_HZ / cycles
    fps_chip = CHIP_HZ / cycles
    print("-" * 60)
    print(f"pixels checked : {npix}")
    print(f"mismatches     : {bad}  -> {'PASS (bit-exact)' if bad == 0 else 'FAIL'}")
    print(f"frame period   : {cycles} clocks ({cyc_per_px:.1f} cyc/px)")
    print(f"FPGA @ {FPGA_HZ/1e6:.0f} MHz : {fps_fpga:.3f} frame/s  ({1e3/fps_fpga:.1f} ms/frame)")
    print(f"GF180 @ {CHIP_HZ/1e6:.0f} MHz : {fps_chip:.3f} frame/s  ({1e3/fps_chip:.1f} ms/frame)")
    print(f"(UART readout of this frame took {rx_dt:.1f}s — that's the link, not the core)")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
