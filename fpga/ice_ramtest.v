/*
 * iCEBreaker on-chip RAM capture test for the TT Mandelbrot.
 *
 * Instantiates the LITERAL TinyTapeout top (tt_um_smerity_mandelbrot) unchanged,
 * lets it free-run its default view, and captures every pixel it emits into
 * on-chip RAM AT FULL CLOCK SPEED with no backpressure -- exactly how the real
 * GF180 chip will run, but with a buffer instead of an RP2040 sink. A free-running
 * counter measures the true frame period (frame_start -> frame_start), so we learn
 * the real frame rate, not the UART-limited one.
 *
 * After a frame is captured it is streamed out over UART for a bit-exact check:
 *   preamble  0xA5 0x5A
 *   W[15:0]   H[15:0]      (big-endian, the captured frame size)
 *   cycles[31:0]           (big-endian, clocks for one full frame)
 *   W*H pixel bytes         (raster order, row 0 first)
 * then it re-arms and captures/dumps the next frame, forever.
 *
 * Storage: two pixels packed per 16-bit word. A 320x240 frame is 76800 bytes =
 * 38400 words, which spans three SB_SPRAM256KA banks (16384 words each). In sim
 * (-DSIM) a behavioural array stands in for the SPRAM so the capture/packing/dump
 * logic is fully exercised by iverilog.
 */

`default_nettype none

module top #(
    parameter integer FRAC         = 28,
    parameter integer W            = 320,
    parameter integer H            = 240,
    parameter integer CLKS_PER_BIT = 104,         // = core_clk / 115200
    // optional PLL to over-clock the core (clock-sweep test). Off by default so
    // the normal build/sim run straight off the 12 MHz pin. Set via yosys chparam.
    parameter         ENABLE_PLL   = 1'b0,
    parameter [3:0]   PLL_DIVR     = 4'd0,
    parameter [6:0]   PLL_DIVF     = 7'd47,        // default 18 MHz from 12 MHz
    parameter [2:0]   PLL_DIVQ     = 3'd5
) (
    input  wire clk,        // 12 MHz pin
    input  wire btn_n,      // user button (active low) -> reset
    output wire TX,         // UART out -> FT2232 channel B
    output wire ledr_n      // heartbeat (active low), toggles per captured frame
);
    // ---------------- core clock (12 MHz pin, or PLL-multiplied) ----------------
    wire core_clk;
    generate
        if (ENABLE_PLL) begin : g_pll
            // PAD PLL: the PLL owns the 12 MHz input pad directly (PLLOUTGLOBAL
            // feeds the global clock net). SB_PLL40_CORE would conflict with the
            // clk pin's SB_IO, so PAD is required here.
            SB_PLL40_PAD #(
                .FEEDBACK_PATH("SIMPLE"),
                .DIVR(PLL_DIVR), .DIVF(PLL_DIVF), .DIVQ(PLL_DIVQ),
                .FILTER_RANGE(3'b001)
            ) pll (
                .PACKAGEPIN(clk), .PLLOUTGLOBAL(core_clk), .PLLOUTCORE(),
                .LOCK(), .RESETB(1'b1), .BYPASS(1'b0)
            );
        end else begin : g_nopll
            assign core_clk = clk;
        end
    endgenerate

    localparam integer NPIX  = W * H;
    localparam integer WORDS = (NPIX + 1) / 2;
    localparam [15:0]  WW    = W[15:0];
    localparam [15:0]  HH    = H[15:0];

    // ---------------- power-on reset + button ----------------
    reg [3:0] por = 0;
    reg       rst_n = 0;
    always @(posedge core_clk) begin
        if (por != 4'hf) por <= por + 1'b1;
        rst_n <= (por == 4'hf) & btn_n;
    end

    // ---------------- the literal TinyTapeout top, free-running ----------------
    wire [7:0] uo, uio;
    tt_um_smerity_mandelbrot #(.FRAC(FRAC), .W(W), .H(H)) dut (
        .ui_in (8'd0),
        .uo_out(uo),
        .uio_in(8'd0),
        .uio_out(uio),
        .uio_oe(),                 // directions fixed inside; we only read [2:0]
        .ena   (1'b1),
        .clk   (core_clk),
        .rst_n (rst_n)
    );
    wire [7:0] pixel       = uo;
    wire       pix_valid   = uio[0];
    wire       frame_start = uio[1];
    // uio[2] = line_end (unused: we count pixels, not lines)

    // ---------------- capture / dump FSM ----------------
    localparam [2:0] S_ARM=3'd0, S_CAP=3'd1, S_HDR=3'd2,
                     S_RD0=3'd3, S_RD1=3'd4, S_SEND=3'd5, S_PIXNEXT=3'd6;
    reg [2:0]  state, ret;
    reg [16:0] idx;             // capture pixel index (0..NPIX)
    reg [16:0] j;               // dump pixel index   (0..NPIX-1)
    reg [31:0] cyc, cyc_total;  // frame-period counter (clocks)
    reg [3:0]  hdr_i;
    reg        tgl;
    assign ledr_n = ~tgl;

    // ---------------- on-chip RAM (2 pixels / 16-bit word) ----------------
    wire        writing  = (state == S_CAP);
    wire [15:0] ram_addr = writing ? idx[16:1] : j[16:1];
    wire        ram_wren = writing & pix_valid & (idx < NPIX);
    wire [3:0]  ram_mask = idx[0] ? 4'b1100 : 4'b0011;          // hi / lo byte
    wire [15:0] ram_din  = idx[0] ? {pixel, 8'd0} : {8'd0, pixel};
    wire [15:0] ram_dout;

`ifdef SIM
    reg [15:0] mem [0:WORDS-1];
    reg [15:0] dout_r;
    always @(posedge core_clk) begin
        if (ram_wren) begin
            if (ram_mask[0]) mem[ram_addr][3:0]   <= ram_din[3:0];
            if (ram_mask[1]) mem[ram_addr][7:4]   <= ram_din[7:4];
            if (ram_mask[2]) mem[ram_addr][11:8]  <= ram_din[11:8];
            if (ram_mask[3]) mem[ram_addr][15:12] <= ram_din[15:12];
        end
        dout_r <= mem[ram_addr];        // 1-cycle read latency, matches SPRAM
    end
    assign ram_dout = dout_r;
`else
    // Three SB_SPRAM256KA banks: addr[15:14] selects, addr[13:0] within bank.
    wire [1:0]  bsel = ram_addr[15:14];
    wire [15:0] d0, d1, d2;
    reg  [1:0]  bsel_r;
    always @(posedge core_clk) bsel_r <= bsel;
    assign ram_dout = (bsel_r == 2'd0) ? d0 : (bsel_r == 2'd1) ? d1 : d2;

    SB_SPRAM256KA bank0 (
        .ADDRESS(ram_addr[13:0]), .DATAIN(ram_din), .MASKWREN(ram_mask),
        .WREN(ram_wren), .CHIPSELECT(bsel == 2'd0), .CLOCK(core_clk),
        .STANDBY(1'b0), .SLEEP(1'b0), .POWEROFF(1'b1), .DATAOUT(d0));
    SB_SPRAM256KA bank1 (
        .ADDRESS(ram_addr[13:0]), .DATAIN(ram_din), .MASKWREN(ram_mask),
        .WREN(ram_wren), .CHIPSELECT(bsel == 2'd1), .CLOCK(core_clk),
        .STANDBY(1'b0), .SLEEP(1'b0), .POWEROFF(1'b1), .DATAOUT(d1));
    SB_SPRAM256KA bank2 (
        .ADDRESS(ram_addr[13:0]), .DATAIN(ram_din), .MASKWREN(ram_mask),
        .WREN(ram_wren), .CHIPSELECT(bsel == 2'd2), .CLOCK(core_clk),
        .STANDBY(1'b0), .SLEEP(1'b0), .POWEROFF(1'b1), .DATAOUT(d2));
`endif

    // ---------------- UART transmit ----------------
    reg  [7:0] tx_data;
    reg        tx_valid;
    wire       tx_busy;
    wire       accepted = tx_valid & tx_busy;
    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk(core_clk), .in_valid(tx_valid), .in_data(tx_data), .tx(TX), .busy(tx_busy));

    function [7:0] hdr_byte(input [3:0] i);
        case (i)
            4'd0: hdr_byte = 8'hA5;
            4'd1: hdr_byte = 8'h5A;
            4'd2: hdr_byte = WW[15:8];
            4'd3: hdr_byte = WW[7:0];
            4'd4: hdr_byte = HH[15:8];
            4'd5: hdr_byte = HH[7:0];
            4'd6: hdr_byte = cyc_total[31:24];
            4'd7: hdr_byte = cyc_total[23:16];
            4'd8: hdr_byte = cyc_total[15:8];
            4'd9: hdr_byte = cyc_total[7:0];
            default: hdr_byte = 8'h00;
        endcase
    endfunction

    always @(posedge core_clk) begin
        if (!rst_n) begin
            state <= S_ARM; ret <= S_ARM;
            idx <= 0; j <= 0; cyc <= 0; cyc_total <= 0; hdr_i <= 0;
            tx_valid <= 1'b0; tx_data <= 8'd0; tgl <= 1'b0;
        end else begin
            case (state)
                // wait for a clean frame boundary, then start capturing
                S_ARM: if (frame_start) begin
                           idx <= 0; cyc <= 0; state <= S_CAP;
                       end
                // capture every pixel at full speed; next frame_start ends the frame
                S_CAP: begin
                           cyc <= cyc + 1'b1;
                           if (pix_valid && idx < NPIX) idx <= idx + 1'b1;
                           if (frame_start && idx == NPIX) begin
                               cyc_total <= cyc;
                               tgl   <= ~tgl;
                               hdr_i <= 0;
                               j     <= 0;
                               state <= S_HDR;
                           end
                       end
                // stream the 10-byte header
                S_HDR: begin
                           tx_data <= hdr_byte(hdr_i);
                           ret     <= (hdr_i == 4'd9) ? S_RD0 : S_HDR;
                           hdr_i   <= hdr_i + 1'b1;
                           state   <= S_SEND;
                       end
                // present pixel word address (1-cycle RAM read latency)
                S_RD0: state <= S_RD1;
                // latch the selected byte and send it
                S_RD1: begin
                           tx_data <= j[0] ? ram_dout[15:8] : ram_dout[7:0];
                           ret     <= S_PIXNEXT;
                           state   <= S_SEND;
                       end
                // shared UART byte sender with backpressure
                S_SEND: if (!tx_valid) begin
                            if (!tx_busy) tx_valid <= 1'b1;
                        end else if (accepted) begin
                            tx_valid <= 1'b0;
                            state    <= ret;
                        end
                S_PIXNEXT: if (j == NPIX-1) state <= S_ARM;   // done -> capture again
                           else begin j <= j + 1'b1; state <= S_RD0; end
                default: state <= S_ARM;
            endcase
        end
    end
endmodule


/* UART transmitter (8N1). iCE40-only -- uses init values. */
module uart_tx #(parameter CLKS_PER_BIT = 104) (
    input  wire clk, input wire in_valid, input wire [7:0] in_data,
    output wire tx, output wire busy
);
    localparam IDLE = 2'd0, START = 2'd1, DATA = 2'd2, STOP = 2'd3;
    reg [1:0] state = IDLE;
    reg [$clog2(CLKS_PER_BIT)-1:0] count = 0;
    reg [2:0] bit_index = 0;
    reg [7:0] data = 0;
    reg       tx_reg = 1'b1;
    wire tick = (count == CLKS_PER_BIT - 1);
    always @(posedge clk) begin
        count <= (state == IDLE || tick) ? 0 : count + 1'b1;
        case (state)
            IDLE:  begin tx_reg <= 1'b1; bit_index <= 0;
                         if (in_valid) begin data <= in_data; state <= START; end end
            START: begin tx_reg <= 1'b0; if (tick) state <= DATA; end
            DATA:  begin tx_reg <= data[bit_index];
                         if (tick) state <= (bit_index == 3'd7) ? STOP : DATA;
                         if (tick && bit_index != 3'd7) bit_index <= bit_index + 1'b1; end
            STOP:  begin tx_reg <= 1'b1; if (tick) state <= IDLE; end
        endcase
    end
    assign tx   = tx_reg;
    assign busy = (state != IDLE);
endmodule

`default_nettype wire
