# Exhaustive regression suite

Bit-exact tests of the taped-out Mandelbrot design, layered from the core math out
to the literal chip top's packet path on real silicon. Every check compares against
an integer reference (`mandel_ref`); all four passed on the shipped design.

| Test | Where | Covers |
|---|---|---|
| 1. Core math sweep | sim | ~5,700 (cx,cy,maxit) pts: grid, deep zoom, escape boundary, in-set, maxit {0..253} |
| 2. Multiplier | sim | smul2 exhaustive W8/W10 + 3M random W32 |
| 3. Full-chain view sweep | FPGA (`fpga/ice_top.v`) | DDA + packet + stream + core, many views |
| 4. Chip packet-path | FPGA (literal `tt_um_smerity_mandelbrot`) | the chip's real `param_valid`/`param_frame` receiver |

## Running

**1. Core math** (sim):
```sh
uv run python gen_points.py
iverilog -g2012 -o sim tb_exhaustive.v ../../src/mandel.v && vvp sim
uv run python check_exhaustive.py
```

**2. Multiplier** (sim):
```sh
iverilog -g2012 -DWVAL=8  -DNRVAL=0       -o m tb_mul.v ../../src/mandel.v && vvp m
iverilog -g2012 -DWVAL=10 -DNRVAL=0       -o m tb_mul.v ../../src/mandel.v && vvp m
iverilog -g2012 -DWVAL=32 -DNRVAL=3000000 -o m tb_mul.v ../../src/mandel.v && vvp m
```

**3. Full-chain view sweep** (iCEBreaker, viewer build):
```sh
(cd ../../fpga && make && make prog)
uv run --with pyserial python sweep_fpga.py        # add /dev/cu.usbserial-* if needed
```

**4. Chip packet-path on silicon** (iCEBreaker, literal chip top via `fpga/ice_pkttest.v`):
```sh
cd ../../fpga
yosys -p "synth_ice40 -top top -json pkt.json" ice_pkttest.v ../src/project.v ../src/mandel.v
nextpnr-ice40 --up5k --package sg48 --pcf icebreaker.pcf --json pkt.json --asc pkt.asc --freq 12
icepack pkt.asc pkt.bin && iceprog pkt.bin
cd ../test/exhaustive
uv run --with pyserial python pkt_silicon.py
```

## Gotchas baked in
- **Race-free handshake:** sim TBs drive inputs `#1` *after* the clock edge. Driving
  `start` exactly on the edge is a scheduling race that can make the core miss a
  launch — it produced one false mismatch before the fix. Always suspect the TB first.
- **In-range views:** all points/views stay within |c| ≲ 2.5 so the Q4.28 datapath
  never overflows (escape at |z|>2 caps the next z at ~6.5 < 8) and the full-precision
  reference matches the RTL bit-for-bit. Past that is an operational-envelope limit,
  not a bug.
