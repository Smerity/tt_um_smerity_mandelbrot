# cocotb test for tt_um_smerity_mandelbrot (TinyTapeout CI).
#
# Port-only and bounded: it resets, checks the bidir directions, waits for the
# first frame, captures the first N pixels of row 0, and checks each against a
# bit-exact integer reference. Fast in both RTL and gate-level sim (the top edge
# of the default view escapes in 1-2 iterations, so it finishes in a few hundred
# cycles regardless of frame size).
#
# These constants MUST match the defaults in src/project.v.

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

FRAC = 28
MAXIT = 100
N = 24                       # pixels of row 0 to check


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


def rd(sig):
    try:
        return int(sig.value)
    except ValueError:        # unresolved (X/Z) — skip this cycle
        return None


@cocotb.test()
async def test_mandel_stream(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 5)

    # bidir directions are combinational, valid even in reset: uio[2:0] out, [7:3] in
    assert int(dut.uio_oe.value) == 0b0000_0111, \
        f"uio_oe = {int(dut.uio_oe.value):08b}, expected 00000111"

    dut.rst_n.value = 1

    # After reset the design deterministically renders row 0 from (0,0), so the
    # first pix_valid pixels ARE row 0 col 0,1,2,... We capture those directly.
    # (Don't gate on frame_start: the first one is a transient right at reset and
    # the next is a whole frame away — far beyond any sane cycle budget.)
    cx0, cy0, step = default_view()
    got = []
    saw_frame_start = False
    for _ in range(1_000_000):
        await RisingEdge(dut.clk)
        uio = rd(dut.uio_out)
        if uio is None:
            continue
        if (uio >> 1) & 1:
            saw_frame_start = True
        if (uio >> 2) & 1:                  # line_end -> end of a row, stop
            break
        if uio & 1:                         # pix_valid
            v = rd(dut.uo_out)
            assert v is not None, "uo_out unresolved on pix_valid"
            got.append(v)
            if len(got) >= N:
                break

    assert len(got) >= N, f"only captured {len(got)} pixels, expected {N}"
    for i, v in enumerate(got[:N]):
        exp = mandel_ref(cx0 + i * step, cy0)
        assert v == exp, f"pixel {i}: got {v}, expected {exp}"

    dut._log.info(f"PASS: {N} pixels bit-exact, uio_oe ok, frame_start seen={saw_frame_start}")
