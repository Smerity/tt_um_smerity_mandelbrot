# iCEBreaker sanity-check build for the TT Mandelbrot (sequential core over UART)
#   make            build mandel.bin
#   make prog       flash it with iceprog
#   make clean
PROJECT := mandel
TOP     := top
PCF     := icebreaker.pcf
DEVICE  := up5k
PACKAGE := sg48
SOURCES := ice_top.v ../src/mandel.v

.PHONY: all prog flash clean
all: $(PROJECT).bin

$(PROJECT).json: $(SOURCES)
	yosys -p "synth_ice40 -top $(TOP) -json $@" $(SOURCES)

$(PROJECT).asc: $(PROJECT).json $(PCF)
	nextpnr-ice40 --$(DEVICE) --package $(PACKAGE) --pcf $(PCF) --json $< --asc $@ --freq 12

$(PROJECT).bin: $(PROJECT).asc
	icepack $< $@

prog flash: $(PROJECT).bin
	iceprog $<

# ---- on-chip RAM capture test (literal TT top + SPRAM buffer) ----
# Renders the default view into on-chip RAM at full clock (no UART backpressure),
# then dumps it for a bit-exact check + true frame-rate measurement.
RAMSRC := ice_ramtest.v ../src/project.v ../src/mandel.v

ramtest.json: $(RAMSRC)
	yosys -p "synth_ice40 -top top -json $@" $(RAMSRC)

ramtest.asc: ramtest.json icebreaker_ramtest.pcf
	nextpnr-ice40 --$(DEVICE) --package $(PACKAGE) --pcf icebreaker_ramtest.pcf --json $< --asc $@ --freq 12

ramtest.bin: ramtest.asc
	icepack $< $@

ramtest: ramtest.bin
ramtest-prog: ramtest.bin
	iceprog $<

# fast behavioural sim of the capture/packing/dump logic (small frame)
ramsim: tb_ramtest.v ice_ramtest.v ../src/project.v ../src/mandel.v
	iverilog -g2012 -DSIM -o ramsim.out $^
	vvp ramsim.out
	uv run python check_ramsim.py

clean:
	rm -f $(PROJECT).json $(PROJECT).asc $(PROJECT).bin \
	      ramtest.json ramtest.asc ramtest.bin ramsim.out sim_rx.txt
