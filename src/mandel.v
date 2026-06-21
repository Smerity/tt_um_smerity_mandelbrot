/*
 * Copyright (c) 2026 Stephen Merity
 * SPDX-License-Identifier: Apache-2.0
 *
 * Shared Mandelbrot core (sequential bit-serial multiplier, Q4.FRAC, runtime maxit).
 * Used by both the TinyTapeout top (project.v) and the iCEBreaker FPGA top (fpga/ice_top.v).
 */

`default_nettype none

module smul #(parameter integer W = 16) (
    input  wire                clk,
    input  wire                rst_n,
    input  wire                start,
    input  wire signed [W-1:0] a, b,
    output reg  signed [2*W-1:0] p,
    output reg                 done
);
    reg               running;
    reg [2*W-1:0]     acc;
    reg [W-1:0]       mcand;
    reg               sgn;
    reg [$clog2(W+1)-1:0] cnt;

    wire [W:0]     high_plus = acc[2*W-1:W] + (acc[0] ? {1'b0, mcand} : {(W+1){1'b0}});
    wire [2*W-1:0] acc_next  = {high_plus, acc[W-1:1]};

    always @(posedge clk) begin
        if (!rst_n) begin
            running <= 1'b0; done <= 1'b0; p <= 0; acc <= 0; mcand <= 0; sgn <= 1'b0; cnt <= 0;
        end else begin
            done <= 1'b0;
            if (start) begin
                acc     <= {{W{1'b0}}, (a[W-1] ? -a : a)};
                mcand   <= (b[W-1] ? -b : b);
                sgn     <= a[W-1] ^ b[W-1];
                cnt     <= W[$clog2(W+1)-1:0];
                running <= 1'b1;
            end else if (running) begin
                acc <= acc_next;
                cnt <= cnt - 1'b1;
                if (cnt == 1) begin
                    running <= 1'b0;
                    done    <= 1'b1;
                    p       <= sgn ? -acc_next : acc_next;
                end
            end
        end
    end
endmodule

/*
 * smul2 — radix-4 Booth sequential multiplier. Drop-in for smul (same ports +
 * start/done handshake, same signed 2W-bit product), but consumes 2 bits of the
 * multiplier per cycle, finishing in W/2 steps instead of W (~2x fewer cycles).
 * Booth is natively signed, so there is no sign-magnitude negate dance.
 *
 * One (2W+2)-bit register P = {accumulator[high], multiplier[low]} plus the Booth
 * overlap bit q1. Each step recodes the window {P[1],P[0],q1} into a digit in
 * {-2,-1,0,+1,+2}, adds digit*a to the high half, then arithmetic-shifts P right
 * by 2. After W/2 steps the signed product is in P[2W-1:0].
 */
module smul2 #(parameter integer W = 16) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  start,
    input  wire signed [W-1:0]   a, b,
    output reg  signed [2*W-1:0] p,
    output reg                   done
);
    localparam integer STEPS = W/2;

    reg                    running;
    reg signed [2*W+1:0]   P;        // {acc (W+2 high bits), multiplier (W low bits)}
    reg                    q1;       // Booth overlap bit (b_{-1})
    reg signed [W+1:0]     Ma, M2;   // +1*a and +2*a, sign-extended to W+2 bits
    reg [$clog2(W/2+1)-1:0] cnt;

    wire [2:0] window = {P[1], P[0], q1};
    reg signed [W+1:0] addend;
    always @(*) begin
        case (window)
            3'b001, 3'b010: addend =  Ma;            // +1
            3'b011:         addend =  M2;            // +2
            3'b100:         addend = -M2;            // -2
            3'b101, 3'b110: addend = -Ma;            // -1
            default:        addend =  {(W+2){1'b0}}; // 000 / 111 -> 0
        endcase
    end

    wire signed [W+1:0]   Ahi   = P[2*W+1 : W];
    wire signed [W+1:0]   Ahi1  = Ahi + addend;
    wire signed [2*W+1:0] Pfull = {Ahi1, P[W-1:0]};
    wire signed [2*W+1:0] Pshft = Pfull >>> 2;

    always @(posedge clk) begin
        if (!rst_n) begin
            running <= 1'b0; done <= 1'b0; p <= 0;
            P <= 0; q1 <= 1'b0; Ma <= 0; M2 <= 0; cnt <= 0;
        end else begin
            done <= 1'b0;
            if (start) begin
                P       <= {{(W+2){1'b0}}, b};
                q1      <= 1'b0;
                Ma      <= {{2{a[W-1]}}, a};         // +1*a
                M2      <= {a[W-1], a, 1'b0};        // +2*a
                cnt     <= STEPS[$clog2(W/2+1)-1:0];
                running <= 1'b1;
            end else if (running) begin
                P  <= Pshft;
                q1 <= P[1];
                cnt <= cnt - 1'b1;
                if (cnt == 1) begin
                    running <= 1'b0;
                    done    <= 1'b1;
                    p       <= Pshft[2*W-1:0];
                end
            end
        end
    end
endmodule

/*
 * mandel — Q4.FRAC iteration, sequential multiplier. `maxit` is a runtime INPUT
 * so the host can change the iteration limit live (on both the TT chip and the
 * iCEBreaker). Bit-exact for any fixed maxit.
 */
module mandel #(
    parameter integer FRAC  = 12,
    parameter integer WIDTH = 16
) (
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    start,
    input  wire signed [WIDTH-1:0] cx, cy,
    input  wire [7:0]              maxit,   // runtime iteration limit
    output reg  [7:0]              value,
    output reg                     busy
);
    localparam [2:0] S_IDLE=3'd0, S_ISSUE=3'd1, S_WAIT=3'd2, S_UPD=3'd3;
    reg [2:0] state;
    reg [1:0] which;

    reg signed [WIDTH-1:0] zr, zi, c_re, c_im;
    reg [7:0] iter;
    reg signed [2*WIDTH-1:0] prr, pii, pri;

    reg signed [WIDTH-1:0] ma, mb;
    always @(*) begin
        case (which)
            2'd1:    begin ma = zi; mb = zi; end
            2'd2:    begin ma = zr; mb = zi; end
            default: begin ma = zr; mb = zr; end
        endcase
    end

    reg  smul_start;
    wire smul_done;
    wire signed [2*WIDTH-1:0] smul_p;
    // radix-4 Booth multiplier (smul2): ~2x fewer cycles than smul, bit-exact.
    // The FSM waits on `done`, so this is a pure drop-in. Flip back to `smul` to A/B.
    smul2 #(.W(WIDTH)) u_smul (
        .clk(clk), .rst_n(rst_n), .start(smul_start),
        .a(ma), .b(mb), .p(smul_p), .done(smul_done));

    wire signed [WIDTH-1:0]   zr2   = prr >>> FRAC;
    wire signed [WIDTH-1:0]   zi2   = pii >>> FRAC;
    wire signed [WIDTH-1:0]   xprod = pri >>> FRAC;
    wire signed [2*WIDTH-1:0] mag2  = (prr + pii) >>> FRAC;
    localparam signed [2*WIDTH-1:0] FOUR = 4;
    wire escaped = mag2 > (FOUR << FRAC);

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE; busy <= 1'b0; value <= 8'b0; which <= 2'd0;
            zr <= 0; zi <= 0; c_re <= 0; c_im <= 0; iter <= 8'b0;
            prr <= 0; pii <= 0; pri <= 0; smul_start <= 1'b0;
        end else begin
            smul_start <= 1'b0;
            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        c_re <= cx; c_im <= cy;
                        zr <= 0; zi <= 0; iter <= 8'b0;
                        which <= 2'd0; busy <= 1'b1;
                        smul_start <= 1'b1; state <= S_WAIT;
                    end
                end
                S_ISSUE: begin smul_start <= 1'b1; state <= S_WAIT; end
                S_WAIT: begin
                    if (smul_done) begin
                        case (which)
                            2'd0: prr <= smul_p;
                            2'd1: pii <= smul_p;
                            2'd2: pri <= smul_p;
                        endcase
                        if (which == 2'd2) state <= S_UPD;
                        else begin which <= which + 2'd1; state <= S_ISSUE; end
                    end
                end
                S_UPD: begin
                    if (escaped)            begin value <= iter; busy <= 1'b0; state <= S_IDLE; end
                    else if (iter == maxit) begin value <= 8'd0; busy <= 1'b0; state <= S_IDLE; end
                    else begin
                        zr   <= zr2 - zi2 + c_re;
                        zi   <= (xprod <<< 1) + c_im;
                        iter <= iter + 8'd1;
                        which <= 2'd0; smul_start <= 1'b1; state <= S_WAIT;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
