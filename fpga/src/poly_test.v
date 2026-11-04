//=============================================================================
// poly_test.v — 32 路复音测试模块
//
//   触发: en 拨高 (SW6 拨到 ON)
//
//   测试序列 (累积式, 便于逐个数声部):
//     0 ms      第 0 路发声
//     200 ms    第 1 路加入, 前面的保持
//     ...
//     6400 ms   32 路全部同时发声   <- 验证复音数 / 混音削顶
//     7400 ms   全部清零, 从头再来
//
//   力度固定 90: 32 路叠加时峰值 = 90 x 32 x 增益, 不会削顶
//
//   输出直接接发声单元:
//     gates[31:0]  —— 每路 gate
//     vels[255:0]  —— 每路力度 (8 位一档)
//=============================================================================
`timescale 1ns/1ps

module poly_test #(
    parameter integer CLK_HZ   = 50_000_000,
    parameter integer STEP_MS  = 200,      // 每 200ms 加一路
    parameter integer HOLD_MS  = 1000,     // 32 路全开保持 1 秒
    parameter integer VEL      = 90        // 固定力度
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire         en,             // 1 = 进入测试
    output reg  [31:0]  gates,          // 32 路 gate
    output wire [255:0] vels            // 32 路力度
);

    localparam integer STEP_CNT = (CLK_HZ / 1000) * STEP_MS;
    localparam integer HOLD_CNT = (CLK_HZ / 1000) * HOLD_MS;

    reg [4:0]  idx;          // 0..31: 下一个要加入的声部
    reg [26:0] cnt;          // 计时
    reg        hold_ph;      // 1 = 32 路全开保持阶段

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            idx     <= 5'd0;
            cnt     <= 27'd0;
            hold_ph <= 1'b0;
            gates   <= 32'd0;
        end else if (!en) begin
            // 关掉立即清零 (拨回 OFF 马上恢复正常演奏)
            idx     <= 5'd0;
            cnt     <= 27'd0;
            hold_ph <= 1'b0;
            gates   <= 32'd0;
        end else if (!hold_ph) begin
            //-------- 累积阶段: 每 STEP_MS 加一路 --------
            if (cnt + 1'b1 >= STEP_CNT) begin
                cnt   <= 27'd0;
                gates <= gates | (32'd1 << idx);
                if (idx == 5'd31) begin
                    hold_ph <= 1'b1;          // 32 路全亮, 进入保持
                    idx     <= 5'd0;
                end else begin
                    idx <= idx + 1'b1;
                end
            end else begin
                cnt <= cnt + 1'b1;
            end
        end else begin
            //-------- 保持阶段: 32 路同时响 HOLD_MS --------
            if (cnt + 1'b1 >= HOLD_CNT) begin
                cnt     <= 27'd0;
                hold_ph <= 1'b0;
                gates   <= 32'd0;             // 清零, 从头再来
            end else begin
                cnt <= cnt + 1'b1;
            end
        end
    end

    // 力度: 有 gate 就给固定值
    genvar gi;
    generate
        for (gi = 0; gi < 32; gi = gi + 1) begin : g_vel
            assign vels[gi*8 +: 8] = gates[gi] ? VEL[7:0] : 8'd0;
        end
    endgenerate

endmodule
