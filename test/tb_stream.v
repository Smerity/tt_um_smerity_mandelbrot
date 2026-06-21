// Port-only testbench: dumps the output protocol byte-stream (frame/line markers
// + pixel values) for a few frames. Used to prove RTL == synthesized gate netlist
// (run both, diff the streams). Works on RTL (params via -P) and on a flattened
// gate netlist (compile with -DGL; the netlist's params are baked in).
`default_nettype none
`timescale 1ns/1ps

module tb_stream;
    parameter integer FRAC  = 28;
    parameter [7:0]   MAXIT = 8'd16;
    parameter integer W     = 6;
    parameter integer H     = 6;
    parameter integer NFRAMES = 3;

    reg        clk = 0, rst_n = 0, ena = 1;
    reg  [7:0] ui_in = 0, uio_in = 0;
    wire [7:0] uo_out, uio_out, uio_oe;

`ifdef GL
    tt_um_smerity_mandelbrot dut (
        .ui_in(ui_in), .uo_out(uo_out), .uio_in(uio_in), .uio_out(uio_out),
        .uio_oe(uio_oe), .ena(ena), .clk(clk), .rst_n(rst_n));
`else
    tt_um_smerity_mandelbrot #(.FRAC(FRAC), .MAXIT(MAXIT), .W(W), .H(H)) dut (
        .ui_in(ui_in), .uo_out(uo_out), .uio_in(uio_in), .uio_out(uio_out),
        .uio_oe(uio_oe), .ena(ena), .clk(clk), .rst_n(rst_n));
`endif

    always #5 clk = ~clk;

    wire pv = uio_out[0], fs = uio_out[1], le = uio_out[2];
    integer fd, frames = 0;
    reg [1023:0] outfile;

    always @(posedge clk) if (rst_n) begin
        if (fs) begin $fwrite(fd, "FF\n"); frames <= frames + 1; end
        if (le) $fwrite(fd, "FE\n");
        if (pv) $fwrite(fd, "%0d\n", uo_out);
    end

    initial begin
        if (!$value$plusargs("out=%s", outfile)) outfile = "stream.txt";
        fd = $fopen(outfile, "w");
        repeat (6) @(posedge clk);
        rst_n <= 1;
        wait (frames == NFRAMES);
        $fclose(fd);
        $display("STREAM_DONE frames=%0d", frames);
        $finish;
    end

    initial begin
        #200_000_000;
        $display("TIMEOUT");
        $fclose(fd); $finish;
    end
endmodule

`default_nettype wire
