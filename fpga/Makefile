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

clean:
	rm -f $(PROJECT).json $(PROJECT).asc $(PROJECT).bin
