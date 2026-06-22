`timescale 1ns/1ps
`default_nettype none
`ifndef WVAL
 `define WVAL 8
`endif
`ifndef NRVAL
 `define NRVAL 0
`endif
module tb_mul;
  parameter integer W = `WVAL;
  parameter integer NRAND = `NRVAL;
  reg clk=0, rst_n=0, start=0;
  reg signed [W-1:0] a, b;
  wire signed [2*W-1:0] p; wire done;
  smul2 #(.W(W)) u(.clk(clk),.rst_n(rst_n),.start(start),.a(a),.b(b),.p(p),.done(done));
  always #5 clk=~clk;
  integer i,j,errs,tests; reg signed [W-1:0] ra,rb;
  task one(input signed [W-1:0] ta, tb_); begin
    @(posedge clk); #1 a=ta; b=tb_; start=1;
    @(posedge clk); #1 start=0;
    @(posedge clk); while(!done) @(posedge clk);
    tests=tests+1;
    if (p !== ta*tb_) begin errs=errs+1;
      if (errs<=10) $display("  WRONG a=%0d b=%0d p=%0d exp=%0d", ta, tb_, p, ta*tb_); end
  end endtask
  initial begin
    rst_n=0; repeat(4) @(posedge clk); rst_n=1; @(posedge clk);
    errs=0; tests=0;
    if (NRAND==0)
      for (i=0;i<(1<<W);i=i+1) for (j=0;j<(1<<W);j=j+1) one(i[W-1:0], j[W-1:0]);
    else
      for (i=0;i<NRAND;i=i+1) begin ra={$random}; rb={$random}; one(ra,rb); end
    $display("W=%0d %s: %0d tests, %0d errs -> %s",
      W, NRAND==0?"EXHAUSTIVE":"RANDOM", tests, errs, errs==0?"PASS":"FAIL");
    $finish;
  end
endmodule
