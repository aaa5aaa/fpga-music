//=============================================================================
// rotary_vol.v — EC11 旋转编码器 -> 20 档对数音量
//
//   vol   : 0~19 (5 位), 每格 +/-1, 转得快时步进自动加大 (1/2)
//   gain_q8: Q8 增益, 256 = 1.0x
//            vol=0  -> 静音
//            vol=13 -> 1.00x; vol=19 -> about 2.00x
//   Slow turns: 1 step/detent; turns faster than 10ms/detent: 2 steps.
//
//   端口: rot_a / rot_b 接 EC11 的 A/B 相, rot_sw 本版未使用(可悬空)
//=============================================================================
`timescale 1ns/1ps

module rotary_vol #(
    parameter integer CLOCK_HZ = 50_000_000
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rot_a,      // EC11 A 相
    input  wire       rot_b,      // EC11 B 相
    input  wire       rot_sw,     // EC11 按键 (本版不用)
    input  wire       lock_vol,   // 1 = 不改变音量(曲库页选择槽位)
    input  wire       pc_set,     // PC 设置音量脉冲
    input  wire [4:0] pc_vol,     // PC 音量 0..19
    output reg  [4:0] vol,        // 0..19 (20 档)
    output reg [9:0]  gain_q8,    // Q8 增益
    output wire       step_o,     // 每走一格的单周期脉冲 (调试用)
    output wire       dir_o       // 1 = 增大, 0 = 减小
);

    //-------------------------------------------------------------------------
    // 两级同步
    //-------------------------------------------------------------------------
    reg a0, a1, b0, b1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin a0<=1'b1; a1<=1'b1; b0<=1'b1; b1<=1'b1; end
        else        begin a0<=rot_a; a1<=a0; b0<=rot_b; b1<=b0; end
    end

    //-------------------------------------------------------------------------
    // 0.2ms 消抖
    //-------------------------------------------------------------------------
    localparam integer DB = CLOCK_HZ / 5000;
    reg [15:0] cnt_a, cnt_b;
    reg        a_db, b_db;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin cnt_a<=0; cnt_b<=0; a_db<=1'b1; b_db<=1'b1; end
        else begin
            if (a1 != a_db) begin
                if (cnt_a >= DB) begin a_db <= a1; cnt_a <= 16'd0; end
                else                    cnt_a <= cnt_a + 1'b1;
            end else cnt_a <= 16'd0;
            if (b1 != b_db) begin
                if (cnt_b >= DB) begin b_db <= b1; cnt_b <= 16'd0; end
                else                    cnt_b <= cnt_b + 1'b1;
            end else cnt_b <= 16'd0;
        end
    end

    //-------------------------------------------------------------------------
    // 正交解码: 每 4 个四分之一步 = 1 格 (EC11 一个定位点)
    //-------------------------------------------------------------------------
    reg  [1:0] q_d;
    wire [1:0] q = {a_db, b_db};
    reg  signed [3:0] acc;
    reg        step;        // 1 = 走了一格
    reg        dir;         // 1 = 增大, 0 = 减小

    wire signed [3:0] acc_p = acc + 4'sd1;
    wire signed [3:0] acc_n = acc - 4'sd1;
    wire fwd  = ({q_d,q} == 4'b00_10) | ({q_d,q} == 4'b10_11) |
                ({q_d,q} == 4'b11_01) | ({q_d,q} == 4'b01_00);
    wire back = ({q_d,q} == 4'b00_01) | ({q_d,q} == 4'b01_11) |
                ({q_d,q} == 4'b11_10) | ({q_d,q} == 4'b10_00);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_d <= 2'b11; acc <= 4'sd0; step <= 1'b0; dir <= 1'b1;
        end else begin
            step <= 1'b0;
            q_d  <= q;
            if (q != q_d) begin
                if (fwd) begin
                    if (acc_p >= 4'sd4) begin acc <= 4'sd0; step <= 1'b1; dir <= 1'b1; end
                    else                     acc <= acc_p;
                end else if (back) begin
                    if (acc_n <= -4'sd4) begin acc <= 4'sd0; step <= 1'b1; dir <= 1'b0; end
                    else                      acc <= acc_n;
                end
            end
        end
    end

    //-------------------------------------------------------------------------
    // 加速: 连续转动的间隔越短, 步进越大
    //-------------------------------------------------------------------------
    reg [19:0] gap;
    localparam integer FAST_TICKS = CLOCK_HZ / 100; // 10ms
    wire fast = (gap < FAST_TICKS);
    wire [4:0] inc = fast ? 5'd2 : 5'd1;

    //-------------------------------------------------------------------------
    // 音量寄存器
    //-------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vol <= 5'd13;      // 上电 = 基础音量 1.0x
            gap <= 20'hFFFFF;
        end else if (pc_set) begin
            vol <= (pc_vol > 5'd19) ? 5'd19 : pc_vol;
        end else if (step) begin
            gap <= 20'd0;
            if (!lock_vol) begin
                if (dir) vol <= (vol > 5'd19 - inc) ? 5'd19 : vol + inc;
                else     vol <= (vol < inc)         ? 5'd0  : vol - inc;
            end
        end else if (gap < 20'hFFFFF) begin
            gap <= gap + 1'b1;
        end
    end

    //-------------------------------------------------------------------------
    // 对数音量表: gain_q8 (256 = 1.0x)
    //   vol 0 -> 0 (静音), 13 -> 256 (1.0x), 19 -> 511 (~2.0x)
    //-------------------------------------------------------------------------
    always @(*) begin
        case (vol)
            5'd0 : gain_q8 = 10'd0;
            5'd1 : gain_q8 = 10'd16;
            5'd2 : gain_q8 = 10'd20;
            5'd3 : gain_q8 = 10'd26;
            5'd4 : gain_q8 = 10'd32;
            5'd5 : gain_q8 = 10'd41;
            5'd6 : gain_q8 = 10'd51;
            5'd7 : gain_q8 = 10'd64;
            5'd8 : gain_q8 = 10'd81;
            5'd9 : gain_q8 = 10'd102;
            5'd10: gain_q8 = 10'd128;
            5'd11: gain_q8 = 10'd162;
            5'd12: gain_q8 = 10'd203;
            5'd13: gain_q8 = 10'd256;
            5'd14: gain_q8 = 10'd287;
            5'd15: gain_q8 = 10'd322;
            5'd16: gain_q8 = 10'd362;
            5'd17: gain_q8 = 10'd406;
            5'd18: gain_q8 = 10'd455;
            5'd19: gain_q8 = 10'd511;
            default: gain_q8 = 10'd256;
        endcase
    end

    assign step_o = step;
    assign dir_o  = dir;

    // rot_sw 本版未使用
    wire unused_sw = rot_sw;

endmodule
