# iCEBreaker FPGA V1.1a sanity check — the TT Mandelbrot, interactive over UART

Run the same core as used on the Tiny Tapeout shuttle but wrapped in a UART streamer.
This enables reasonable confidence this should run in the real world!

The main difference is that the Mandelbrot core remains the same, including sequential multiplier, but there's an I/O wrapper.
We serialize with backpressure such that the stream FSM waits for each byte to be accepted.

Using `viewer.py` you can pan, zoom, change, and explore.
Note that UART is _slow_ so it is actually communication limited.

Fits the UP5k easily, 1559/5280 logic cells (or 29%), and doesn't use DSP or RAM.

## Build & run

```sh
make            # synth_ice40 + nextpnr + icepack -> mandel.bin
make prog       # flash with iceprog
# then, in another terminal (self-contained viewer in this folder):
uv run --with pyserial --with pygame python viewer.py
```

On reset it renders the default full view. The viewer then drives it:

| Key | Action |
|---|---|
| arrows (hold) / left-click | pan |
| `+` / `-` / mouse wheel | zoom (wheel zooms toward the cursor) |
| `[` / `]` | MAXIT down / up |
| `f` / space | render the current view at FULL resolution |
| `p` | toggle "auto full-res when idle" |
| `r` | reset to the full view |