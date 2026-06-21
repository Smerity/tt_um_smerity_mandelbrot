`default_nettype none
`timescale 1ns/1ps
// Drives a control packet into RX (pan/zoom/maxit/resolution), then decodes the
// TX pixel stream and checks it matches the reference for THAT view + maxit.
// Verifies the full interactive path: uart_rx -> packet receiver -> DDA -> core.
module tb_ice;
  parameter integer FRAC=28, CLKS_PER_BIT=8;
  parameter integer PW=12, PH=8;           // packet (preview) resolution
  parameter [7:0]   PMAXIT=8'd16;
  parameter integer NBYTES=120;

  reg clk=0, btn_n=1, RX=1;
  wire TX, ledr_n;
  top #(.FRAC(FRAC), .CLKS_PER_BIT(CLKS_PER_BIT)) dut(
    .clk(clk), .btn_n(btn_n), .RX(RX), .TX(TX), .ledr_n(ledr_n));
  always #5 clk=~clk;

  // packet view (whole set), Q4.28
  localparam signed [31:0] PSTEP = (7 <<< FRAC) / (2*PW);
  localparam signed [31:0] PCX   = -(5 <<< (FRAC-1));      // -2.5
  localparam signed [31:0] PCY   = -((PH/2) * PSTEP);

  task send_byte(input [7:0] b);
    integer k;
    begin
      RX = 1'b0; repeat (CLKS_PER_BIT) @(posedge clk);            // start
      for (k=0;k<8;k=k+1) begin RX=b[k]; repeat (CLKS_PER_BIT) @(posedge clk); end
      RX = 1'b1; repeat (CLKS_PER_BIT) @(posedge clk);            // stop
      repeat (CLKS_PER_BIT) @(posedge clk);                       // idle gap
    end
  endtask

  task send_packet;
    begin
      send_byte(8'hC3);                                  // header
      send_byte(PCX[31:24]); send_byte(PCX[23:16]); send_byte(PCX[15:8]); send_byte(PCX[7:0]);
      send_byte(PCY[31:24]); send_byte(PCY[23:16]); send_byte(PCY[15:8]); send_byte(PCY[7:0]);
      send_byte(PSTEP[31:24]); send_byte(PSTEP[23:16]); send_byte(PSTEP[15:8]); send_byte(PSTEP[7:0]);
      send_byte(PMAXIT);
      send_byte(8'd0); send_byte(PW[7:0]);               // W (16-bit)
      send_byte(8'd0); send_byte(PH[7:0]);               // H (16-bit)
    end
  endtask

  // TX decoder (only records once `capturing` is set, so we get clean packet-view frames)
  integer fd, nbytes=0; reg capturing=0;
  reg [2:0] rxst=0; integer rxcnt=0, rxbit=0; reg [7:0] rxbyte=0;
  always @(posedge clk) begin
    case (rxst)
      0: if (!TX) begin rxcnt <= CLKS_PER_BIT + CLKS_PER_BIT/2 - 1; rxbit<=0; rxst<=1; end
      1: if (rxcnt==0) begin
            rxbyte <= {TX, rxbyte[7:1]};
            if (rxbit==7) rxst<=2; else begin rxbit<=rxbit+1; rxcnt<=CLKS_PER_BIT-1; end
         end else rxcnt <= rxcnt-1;
      2: begin if (capturing) begin $fwrite(fd,"%0d\n", rxbyte); nbytes<=nbytes+1; end rxst<=3; end
      3: if (TX) rxst<=0;
    endcase
  end

  initial begin
    fd=$fopen("ice_bytes.txt","w");
    btn_n=0; repeat(20) @(posedge clk); btn_n=1;
    repeat(20) @(posedge clk);
    send_packet;                                 // pan/zoom/maxit/resolution
    repeat(4000) @(posedge clk);                 // let it commit + settle on the new view
    capturing = 1;                               // capture clean packet-view frames
    wait(nbytes==NBYTES);
    $fclose(fd); $display("ICE_DONE bytes=%0d", nbytes); $finish;
  end
  initial begin #80_000_000; $display("TIMEOUT"); $fclose(fd); $finish; end
endmodule
`default_nettype wire
