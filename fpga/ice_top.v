/*
 * Interactive iCEBreaker top for the TT Mandelbrot sanity check.
 *
 * Renders the same verified sequential core (mandel + smul) and streams pixels
 * to viewer.py over UART (0xFF new frame, 0xFE end of scanline, else pixel).
 * Adds a HOST -> FPGA control channel on RX so the viewer can pan, zoom, change
 * MAXIT, and switch resolution (for a fast preview) live.
 *
 * Control packet (host -> FPGA), 0xC3 header + 17 payload bytes, MSB-first:
 *   corner_x[31:0]  corner_y[31:0]  step[31:0]   (Q4.FRAC, signed)
 *   maxit[7:0]   W[15:0]   H[15:0]
 * The view commits at the next pixel boundary (near-immediate frame restart),
 * so dragging feels responsive (pair with a small W/H preview).
 */

`default_nettype none

module top #(
    parameter integer FRAC         = 28,
    parameter integer W            = 320,        // default/reset width
    parameter integer H            = 240,        // default/reset height
    parameter integer CLKS_PER_BIT = 104         // 12 MHz / 115200
) (
    input  wire clk,        // 12 MHz
    input  wire btn_n,      // user button (active low) — reset to default view
    input  wire RX,         // UART in  <- FT2232 channel B (host TX)
    output wire TX,         // UART out -> FT2232 channel B
    output wire ledr_n      // heartbeat (active low)
);
    localparam integer WIDTH = 4 + FRAC;

    // default full view (Q4.FRAC) for W=320, centred on (-0.5, 0)
    localparam signed [WIDTH-1:0] DEF_STEP = (7 <<< FRAC) / (2*W);
    localparam signed [WIDTH-1:0] DEF_CX   = -((1 <<< (FRAC-1)) + (W/2)*DEF_STEP);
    localparam signed [WIDTH-1:0] DEF_CY   = -((H/2) * DEF_STEP);

    // power-on reset + button
    reg [3:0] por = 0;
    reg       rst_n = 0;
    always @(posedge clk) begin
        if (por != 4'hf) por <= por + 1'b1;
        rst_n <= (por == 4'hf) & btn_n;
    end

    // ---------------- UART receive + control-packet decode ----------------
    wire [7:0] rx_data;
    wire       rx_valid;
    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (
        .clk(clk), .rst_n(rst_n), .rx(RX), .data(rx_data), .valid(rx_valid));

    reg [135:0] rx_shadow;          // 17 payload bytes
    reg [4:0]   rx_count;
    reg         rx_collecting;
    reg         view_pending;
    wire        commit;             // pulse from the stream FSM when it loads the view

    always @(posedge clk) begin
        if (!rst_n) begin
            rx_collecting <= 1'b0; rx_count <= 0; view_pending <= 1'b0; rx_shadow <= 0;
        end else begin
            if (rx_valid) begin
                if (!rx_collecting) begin
                    if (rx_data == 8'hC3) begin rx_collecting <= 1'b1; rx_count <= 0; end
                end else begin
                    rx_shadow <= {rx_shadow[127:0], rx_data};
                    if (rx_count == 5'd16) begin rx_collecting <= 1'b0; view_pending <= 1'b1; end
                    else rx_count <= rx_count + 5'd1;
                end
            end
            if (commit) view_pending <= 1'b0;
        end
    end

    // ---------------- live view registers (default on reset, loaded on commit) ----------------
    reg signed [WIDTH-1:0] corner_x, corner_y, step, cx, cy;
    reg [7:0]  maxit_r;
    reg [9:0]  frame_w;
    reg [8:0]  frame_h;
    reg [9:0]  x;
    reg [8:0]  y;

    // ---------------- Mandelbrot core ----------------
    reg        m_start;
    wire       m_busy;
    wire [7:0] m_value;
    mandel #(.FRAC(FRAC), .WIDTH(WIDTH)) core (
        .clk(clk), .rst_n(rst_n), .start(m_start),
        .cx(cx), .cy(cy), .maxit(maxit_r), .value(m_value), .busy(m_busy));

    // ---------------- UART transmit ----------------
    reg  [7:0] tx_data;
    reg        tx_valid;
    wire       tx_busy;
    wire       accepted = tx_valid && tx_busy;
    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk(clk), .in_valid(tx_valid), .in_data(tx_data), .tx(TX), .busy(tx_busy));

    // ---------------- stream FSM with UART backpressure + responsive view restart ----------------
    localparam [3:0]
        S_FRAME=4'd0, S_AFRAME=4'd1, S_PSTART=4'd2, S_PBUSY=4'd3,
        S_PDONE=4'd4, S_APIX=4'd5, S_EOL=4'd6, S_AEOL=4'd7, S_SEND=4'd8;
    reg [3:0] st, ret;
    reg       commit_r, frame_tgl;
    assign commit = commit_r;
    assign ledr_n = ~frame_tgl;

    always @(posedge clk) begin
        if (!rst_n) begin
            st <= S_FRAME; ret <= S_FRAME;
            x <= 0; y <= 0; cx <= DEF_CX; cy <= DEF_CY;
            corner_x <= DEF_CX; corner_y <= DEF_CY; step <= DEF_STEP;
            maxit_r <= 8'd100; frame_w <= W[9:0]; frame_h <= H[8:0];
            m_start <= 1'b0; tx_valid <= 1'b0; tx_data <= 8'b0; commit_r <= 1'b0; frame_tgl <= 1'b0;
        end else begin
            m_start <= 1'b0; commit_r <= 1'b0;
            case (st)
                S_FRAME:  begin tx_data <= 8'hFF; ret <= S_AFRAME; st <= S_SEND;
                                frame_tgl <= ~frame_tgl; end
                S_AFRAME: begin x <= 0; y <= 0; cx <= corner_x; cy <= corner_y; st <= S_PSTART; end
                S_PSTART:
                    if (view_pending) begin               // new view -> load it and restart now
                        corner_x <= rx_shadow[135:104];
                        corner_y <= rx_shadow[103:72];
                        step     <= rx_shadow[71:40];
                        maxit_r  <= rx_shadow[39:32];
                        frame_w  <= rx_shadow[25:16];
                        frame_h  <= rx_shadow[8:0];
                        commit_r <= 1'b1;
                        st <= S_FRAME;
                    end else begin
                        m_start <= 1'b1; st <= S_PBUSY;
                    end
                S_PBUSY:  if (m_busy)  st <= S_PDONE;
                S_PDONE:  if (!m_busy) begin tx_data <= m_value; ret <= S_APIX; st <= S_SEND; end
                S_APIX:   if (x == frame_w-1) st <= S_EOL;
                          else begin x <= x + 10'd1; cx <= cx + step; st <= S_PSTART; end
                S_EOL:    begin tx_data <= 8'hFE; ret <= S_AEOL; st <= S_SEND; end
                S_AEOL:   if (y == frame_h-1) st <= S_FRAME;
                          else begin y <= y + 9'd1; cy <= cy + step;
                                     x <= 0; cx <= corner_x; st <= S_PSTART; end
                S_SEND:   if (!tx_valid) begin
                              if (!tx_busy) tx_valid <= 1'b1;
                          end else if (accepted) begin
                              tx_valid <= 1'b0; st <= ret;
                          end
                default:  st <= S_FRAME;
            endcase
        end
    end
endmodule


/* UART transmitter (115200 8N1). iCE40-only — uses init values. */
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


/* UART receiver (115200 8N1). Synchronises rx, samples mid-bit, LSB-first. */
module uart_rx #(parameter CLKS_PER_BIT = 104) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx,
    output reg  [7:0] data,
    output reg        valid     // 1-cycle pulse when a byte completes
);
    localparam IDLE=2'd0, START=2'd1, DATA=2'd2, STOP=2'd3;
    reg [1:0] state;
    reg [$clog2(CLKS_PER_BIT)-1:0] count;
    reg [2:0] bit_index;
    reg [1:0] rx_sync;                       // 2-FF synchroniser (CDC)
    wire rx_s = rx_sync[1];

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE; count <= 0; bit_index <= 0; data <= 0; valid <= 0; rx_sync <= 2'b11;
        end else begin
            rx_sync <= {rx_sync[0], rx};
            valid <= 1'b0;
            case (state)
                IDLE:  begin count <= 0; bit_index <= 0; if (!rx_s) state <= START; end
                START: if (count == CLKS_PER_BIT/2 - 1) begin
                           if (!rx_s) begin count <= 0; state <= DATA; end  // real start
                           else state <= IDLE;                              // glitch
                       end else count <= count + 1'b1;
                DATA:  if (count == CLKS_PER_BIT-1) begin
                           count <= 0;
                           data <= {rx_s, data[7:1]};                       // LSB first
                           if (bit_index == 3'd7) state <= STOP;
                           else bit_index <= bit_index + 1'b1;
                       end else count <= count + 1'b1;
                STOP:  if (count == CLKS_PER_BIT-1) begin valid <= 1'b1; state <= IDLE; end
                       else count <= count + 1'b1;
            endcase
        end
    end
endmodule

`default_nettype wire
