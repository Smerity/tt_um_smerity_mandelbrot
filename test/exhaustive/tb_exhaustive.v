// Drives the mandel core directly with every (cx,cy,maxit) point in points.txt
// and writes the resulting iteration value per line to results.txt. A companion
// check_exhaustive.py compares each against a bit-exact reference.
//   iverilog -g2012 -o sim tb_exhaustive.v ../../src/mandel.v ; vvp sim
`timescale 1ns/1ps
`default_nettype none

module tb_exhaustive;
    localparam integer FRAC = 28, WIDTH = 32;

    reg clk = 0, rst_n = 0, start = 0;
    reg signed [WIDTH-1:0] cx, cy;
    reg [7:0] maxit;
    wire [7:0] value;
    wire       busy;

    mandel #(.FRAC(FRAC), .WIDTH(WIDTH)) dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .cx(cx), .cy(cy), .maxit(maxit), .value(value), .busy(busy));

    always #5 clk = ~clk;

    integer fin, fout, n;
    integer icx, icy, im;

    initial begin
        cx = 0; cy = 0; maxit = 0;
        repeat (6) @(posedge clk);
        rst_n = 1; @(posedge clk);

        fin = $fopen("points.txt", "r");
        if (fin == 0) begin $display("ERROR: points.txt not found"); $finish; end
        fout = $fopen("results.txt", "w");
        n = 0;

        while ($fscanf(fin, "%d %d %d\n", icx, icy, im) == 3) begin
            // drive inputs #1 AFTER the edge so the core samples stable values
            // (avoids a start/clk race that can make the core miss a launch)
            @(posedge clk); #1 cx = icx; cy = icy; maxit = im[7:0]; start = 1;
            @(posedge clk); #1 start = 0;
            @(posedge clk);
            while (busy) @(posedge clk);    // run to completion
            $fwrite(fout, "%0d\n", value);
            n = n + 1;
        end

        $fclose(fin); $fclose(fout);
        $display("DONE: %0d points", n);
        $finish;
    end

    initial begin #2000000000; $display("TIMEOUT"); $finish; end
endmodule

`default_nettype wire
