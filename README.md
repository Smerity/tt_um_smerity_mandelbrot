# Smerity-Mandelbrot — a fixed-point Mandelbrot for TinyTapeout (GF180)

An interactive fixed-point Mandelbrot iterator.

![The TinyTapeout core running on an iCEBreaker FPGA, panned and zoomed into the
Mandelbrot set's seahorse valley](assets/fpga_screenshot.png)

*The exact TinyTapeout core (same sequential datapath, wrapped in a UART
streamer) running live on an iCEBreaker FPGA — interactively panned and zoomed
via [`fpga/viewer.py`](fpga/viewer.py).*

See [`docs/info.md`](docs/info.md) for how it works, the pin map, and the host
protocol.

## License

Apache-2.0 (see [`LICENSE`](LICENSE)).
