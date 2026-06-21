// Self-checking testbench runnable with plain iverilog (no cocotb).
// It (a) asserts the stream structure in-sim, and (b) dumps every emitted
// pixel as "<mode> <cx> <cy> <value>" to pixels.txt for the Python checker,
// which compares each against a bit-exact reference. It also exercises the
// host view-packet path (sends a "whole set" view mid-run).
`default_nettype none
`timescale 1ns/1ps

module tb_selfcheck;
    parameter integer FRAC  = 28;
    parameter [7:0]   MAXIT = 8'd100;
    parameter integer W     = 16;
    parameter integer H     = 12;
    localparam integer WIDTH = 4 + FRAC;

    reg        clk = 0, rst_n = 0, ena = 1;
    reg  [7:0] ui_in = 0, uio_in = 0;
    wire [7:0] uo_out, uio_out, uio_oe;

    reg  [7:0] mode = "D";
    integer    fd;
    integer    row_pixels = 0, frame_rows = 0, frame_count = 0;

    tt_um_smerity_mandelbrot #(.FRAC(FRAC), .MAXIT(MAXIT), .W(W), .H(H)) dut (
        .ui_in(ui_in), .uo_out(uo_out), .uio_in(uio_in), .uio_out(uio_out),
        .uio_oe(uio_oe), .ena(ena), .clk(clk), .rst_n(rst_n));

    always #5 clk = ~clk;

    wire pix_valid   = uio_out[0];
    wire frame_start = uio_out[1];
    wire line_end    = uio_out[2];

    // uo_out/pix_valid are registered (appear 1 clk after S_EMIT), but cx/cy
    // increment at S_EMIT — so the coordinate matching this cycle's value is the
    // PREVIOUS cycle's cx/cy. Delay them by one clock to realign.
    reg signed [WIDTH-1:0] cx_d, cy_d;
    always @(posedge clk) begin cx_d <= dut.cx; cy_d <= dut.cy; end

    // structural checks + per-pixel dump
    always @(posedge clk) if (rst_n) begin
        if (pix_valid) begin
            row_pixels <= row_pixels + 1;
            $fwrite(fd, "%c %0d %0d %0d\n", mode, $signed(cx_d), $signed(cy_d), uo_out);
        end
        if (line_end) begin
            if (row_pixels != W) begin
                $display("STRUCT FAIL: row had %0d pixels, expected %0d", row_pixels, W);
                $fclose(fd); $finish;
            end
            row_pixels <= 0;
            frame_rows <= frame_rows + 1;
        end
        if (frame_start) begin
            if (frame_count > 0 && frame_rows != H) begin
                $display("STRUCT FAIL: frame had %0d rows, expected %0d", frame_rows, H);
                $fclose(fd); $finish;
            end
            frame_rows  <= 0;
            frame_count <= frame_count + 1;
        end
    end

    task send_packet(input signed [WIDTH-1:0] cx0, input signed [WIDTH-1:0] cy0,
                     input signed [WIDTH-1:0] stp, input [7:0] mxit);
        integer i, nb;
        reg [3*WIDTH+7:0] pkt;
        begin
            pkt = {cx0, cy0, stp, mxit};  // MSB-first: corner_x, corner_y, step, maxit
            nb  = 3 * (WIDTH/8) + 1;
            uio_in[4] = 1'b1;             // param_frame
            repeat (4) @(posedge clk);
            for (i = nb-1; i >= 0; i = i-1) begin
                ui_in     = pkt[i*8 +: 8];
                uio_in[3] = 1'b1;         // param_valid
                repeat (4) @(posedge clk);
                uio_in[3] = 1'b0;
                repeat (4) @(posedge clk);
            end
            uio_in[4] = 1'b0; ui_in = 0;  // commit gets armed
            repeat (4) @(posedge clk);
        end
    endtask

    // whole-set view for the packet phase
    localparam signed [WIDTH-1:0] PK_STEP = (7 <<< FRAC) / (2*W);
    localparam signed [WIDTH-1:0] PK_CX   = -(5 <<< (FRAC-1));      // -2.5
    localparam signed [WIDTH-1:0] PK_CY   = -((H/2) * PK_STEP);

    initial begin
        fd = $fopen("pixels.txt", "w");
        repeat (6) @(posedge clk);
        rst_n = 1;
        wait (frame_count == 2);          // ~1 full default-view frame captured
        send_packet(PK_CX, PK_CY, PK_STEP, MAXIT);   // same maxit as the reference
        mode = "P";
        wait (frame_count == 5);          // a couple frames after the view change
        $fclose(fd);
        $display("DONE frames=%0d", frame_count);
        $finish;
    end

    initial begin
        #5_000_000;                       // safety timeout
        $display("TIMEOUT");
        $fclose(fd); $finish;
    end
endmodule

`default_nettype wire
