/*
 * Copyright (c) 2026 Stephen Merity
 * SPDX-License-Identifier: Apache-2.0
 *
 * TinyTapeout top: host-driven Mandelbrot (GF180).
 * Streams 8-bit iteration counts; host sends corner/step/maxit over ui_in.
 * Core is in mandel.v.
 */

`default_nettype none

module tt_um_smerity_mandelbrot #(
    parameter integer FRAC  = 28,             // 12 (Q4.12), 20 (Q4.20), 28 (Q4.28)
    parameter [7:0]   MAXIT = 8'd100,         // <= 253 (keeps pixel bytes < 0xFE)
    parameter integer W     = 320,            // frame width  (override small for sim)
    parameter integer H     = 240             // frame height (override small for sim)
) (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);
    // ---------------- fixed-point format ----------------
    localparam integer INT   = 4;             // fixed by the Mandelbrot range
    localparam integer WIDTH = INT + FRAC;    // 16 / 24 / 32

    // ---------------- default view (Q4.FRAC), centred on (-0.5, 0) ----------------
    localparam signed [WIDTH-1:0] DEF_STEP = (7 << FRAC) / 640;             // ~3.5/320 per px
    localparam signed [WIDTH-1:0] DEF_CX   = -((1 << (FRAC-1)) + 160*DEF_STEP); // -0.5 - W/2*step
    localparam signed [WIDTH-1:0] DEF_CY   = -(120 * DEF_STEP);                 //       - H/2*step

    // uio[2:0] drive out (strobes); uio[7:3] are inputs.
    assign uio_oe = 8'b0000_0111;

    // ================= reset synchroniser =================
    // rst_n is an input pad fanning out to every register's reset -- an off-chip-
    // delayed, huge-fanout net that was the design's critical path. Register it
    // twice so the design's reset is driven by a flop (register-to-register,
    // balanced by the tool) instead of the pad, and to guard rst_n against
    // metastability. Reset releases ~2 clocks later than the pad: bit-exact, since
    // the framework holds rst_n low for many cycles and the frame just starts a
    // couple cycles afterward. Everything below uses `rstn`, not `rst_n`.
    reg [1:0] rst_sync = 2'b00;
    always @(posedge clk) rst_sync <= {rst_sync[0], rst_n};
    wire rstn = rst_sync[1];

    // ================= input synchronisers (CDC) =================
    reg [1:0] pv_sync, pf_sync;
    always @(posedge clk) begin
        if (!rstn) begin pv_sync <= 2'b0; pf_sync <= 2'b0; end
        else begin
            pv_sync <= {pv_sync[0], uio_in[3]};
            pf_sync <= {pf_sync[0], uio_in[4]};
        end
    end
    wire param_valid = pv_sync[1];
    wire param_frame = pf_sync[1];

    // ================= view-packet receiver =================
    // 4 fields, MSB-first: corner_x, corner_y, step (WIDTH bits each), maxit (8 bits).
    reg [3*WIDTH+7:0] shadow;
    reg               pv_d, pf_d;
    reg               view_pending;
    wire pv_rise = param_valid & ~pv_d;
    wire pf_fall = ~param_frame & pf_d;
    wire commit;                              // 1-clk pulse from the FSM at frame end

    always @(posedge clk) begin
        if (!rstn) begin
            shadow <= {(3*WIDTH+8){1'b0}}; pv_d <= 1'b0; pf_d <= 1'b0; view_pending <= 1'b0;
        end else begin
            pv_d <= param_valid;
            pf_d <= param_frame;
            if (param_frame & pv_rise) shadow <= {shadow[3*WIDTH-1:0], ui_in}; // shift a byte in
            if (pf_fall)      view_pending <= 1'b1;     // packet complete
            else if (commit)  view_pending <= 1'b0;     // consumed at the next frame
        end
    end

    // ================= live view + DDA + stream FSM =================
    reg signed [WIDTH-1:0] corner_x, corner_y, step;
    reg [7:0]              maxit_r;            // runtime iteration limit (loaded from packet)
    reg signed [WIDTH-1:0] cx, cy;            // coordinate of the current pixel
    reg [8:0] x;                              // 0..319
    reg [7:0] y;                              // 0..239

    localparam [2:0] S_FRAME=3'd0, S_START=3'd1, S_BUSY=3'd2,
                     S_DONE=3'd3, S_EMIT=3'd4, S_LINEEND=3'd5;
    reg [2:0] phase;

    reg        m_start;
    wire       m_busy;
    wire [7:0] m_value;

    reg [7:0]  pix;
    reg        pix_valid, frame_start, line_end;

    assign commit = (phase == S_LINEEND) & (y == H-1) & view_pending;

    always @(posedge clk) begin
        if (!rstn) begin
            phase <= S_FRAME; x <= 9'b0; y <= 8'b0;
            cx <= DEF_CX; cy <= DEF_CY;
            corner_x <= DEF_CX; corner_y <= DEF_CY; step <= DEF_STEP; maxit_r <= MAXIT;
            m_start <= 1'b0;
            pix <= 8'b0; pix_valid <= 1'b0; frame_start <= 1'b0; line_end <= 1'b0;
        end else begin
            m_start <= 1'b0; pix_valid <= 1'b0; frame_start <= 1'b0; line_end <= 1'b0;
            case (phase)
                S_FRAME: begin                       // top-left of a frame
                    frame_start <= 1'b1;
                    x <= 9'b0; y <= 8'b0;
                    cx <= corner_x; cy <= corner_y;
                    phase <= S_START;
                end
                S_START:  begin m_start <= 1'b1; phase <= S_BUSY; end
                S_BUSY:   if (m_busy)  phase <= S_DONE;   // mandel acknowledged
                S_DONE:   if (!m_busy) phase <= S_EMIT;   // computation finished
                S_EMIT: begin                        // hand the pixel to the host
                    pix <= m_value; pix_valid <= 1'b1;
                    if (x == W-1) phase <= S_LINEEND;
                    else begin x <= x + 9'd1; cx <= cx + step; phase <= S_START; end
                end
                S_LINEEND: begin
                    line_end <= 1'b1;
                    if (y == H-1) begin              // frame complete -> maybe load new view
                        if (view_pending) begin
                            corner_x <= shadow[3*WIDTH+7 : 2*WIDTH+8];
                            corner_y <= shadow[2*WIDTH+7 : WIDTH+8];
                            step     <= shadow[WIDTH+7 : 8];
                            maxit_r  <= shadow[7:0];
                        end
                        phase <= S_FRAME;
                    end else begin
                        x  <= 9'b0;                  // restart the row at the left edge
                        y  <= y + 8'd1;
                        cy <= cy + step;
                        cx <= corner_x;
                        phase <= S_START;
                    end
                end
                default: phase <= S_FRAME;
            endcase
        end
    end

    mandel #(.FRAC(FRAC), .WIDTH(WIDTH)) core (
        .clk(clk), .rst_n(rstn), .start(m_start),
        .cx(cx), .cy(cy), .maxit(maxit_r), .value(m_value), .busy(m_busy)
    );

    // ================= pins =================
    assign uo_out       = pix;
    assign uio_out[0]   = pix_valid;
    assign uio_out[1]   = frame_start;
    assign uio_out[2]   = line_end;
    assign uio_out[7:3] = 5'b0;

    // tie off unused inputs (ena, output-configured uio inputs, spare uio)
    wire _unused = &{ena, uio_in[2:0], uio_in[7:5], 1'b0};
endmodule
`default_nettype wire
