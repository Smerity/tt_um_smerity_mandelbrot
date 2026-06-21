/*
 * Sim for ice_ramtest.v: decode the real TX line, dump the received frame, and
 * report the measured cycle count. Run with -DSIM (behavioural RAM) and a small
 * frame so iverilog finishes quickly. A companion check_ramsim.py verifies the
 * captured pixels against the bit-exact reference.
 */
`timescale 1ns/1ps
`default_nettype none

module tb_ramtest;
    localparam integer FRAC = 28;
    localparam integer W    = 6;
    localparam integer H    = 4;
    localparam integer CPB  = 8;          // small CLKS_PER_BIT for fast UART in sim
    localparam integer NPIX = W * H;

    reg clk = 0;
    always #5 clk = ~clk;                 // sim clock (rate is arbitrary)

    reg btn_n = 1'b1;
    wire TX, ledr_n;

    top #(.FRAC(FRAC), .W(W), .H(H), .CLKS_PER_BIT(CPB)) dut (
        .clk(clk), .btn_n(btn_n), .TX(TX), .ledr_n(ledr_n));

    // --- UART receive (8N1, LSB first), mirrors the transmitter timing ---
    task get_byte(output [7:0] b);
        integer k;
        begin
            @(negedge TX);                                  // start bit edge
            repeat (CPB + CPB/2) @(posedge clk);            // -> middle of bit 0
            for (k = 0; k < 8; k = k + 1) begin
                b[k] = TX;
                repeat (CPB) @(posedge clk);
            end
        end
    endtask

    integer fd, i;
    reg [7:0]  c, c2;
    reg        found;
    reg [15:0] rw, rh;
    reg [31:0] rcyc;
    reg [7:0]  hb [0:7];
    reg [7:0]  pix [0:NPIX-1];

    initial begin : RX
        // sync on the 0xA5 0x5A preamble
        found = 1'b0;
        while (!found) begin
            get_byte(c);
            if (c == 8'hA5) begin
                get_byte(c2);
                if (c2 == 8'h5A) found = 1'b1;
            end
        end
        // header: W, H, cycles (big-endian)
        get_byte(hb[0]); get_byte(hb[1]); rw   = {hb[0], hb[1]};
        get_byte(hb[2]); get_byte(hb[3]); rh   = {hb[2], hb[3]};
        get_byte(hb[4]); get_byte(hb[5]);
        get_byte(hb[6]); get_byte(hb[7]); rcyc = {hb[4], hb[5], hb[6], hb[7]};
        // pixels, raster order
        for (i = 0; i < NPIX; i = i + 1) get_byte(pix[i]);

        $display("RX done: W=%0d H=%0d cycles=%0d", rw, rh, rcyc);
        fd = $fopen("sim_rx.txt", "w");
        $fwrite(fd, "%0d %0d %0d\n", rw, rh, rcyc);
        for (i = 0; i < NPIX; i = i + 1) $fwrite(fd, "%0d\n", pix[i]);
        $fclose(fd);
        $finish;
    end

    initial begin
        #50000000;                          // safety timeout
        $display("TIMEOUT");
        $finish;
    end
endmodule

`default_nettype wire
