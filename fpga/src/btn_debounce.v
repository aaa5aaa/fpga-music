//=============================================================================
// btn_debounce.v — 独立按键去抖 (电平 + 按下脉冲)
//
//   两路信号同步 -> 稳定 15 ms 才认可 -> 输出
//     level : 去抖后的电平 (1 = 按下), 用于"按住生效、松开恢复"
//     press : 按下瞬间的单周期脉冲,   用于"点一下切换"
//
//   比原来的 control_keys 更可靠: 是"连续 15 ms 一致"判定, 不是单点采样,
//   所以机械抖动不会造成一次按下被识别成多次.
//=============================================================================
`timescale 1ns/1ps

module btn_debounce #(
    parameter integer CLOCK_HZ = 50_000_000,
    parameter integer MS       = 15
)(
    input  wire clk,
    input  wire rst_n,
    input  wire btn_n,          // 低有效: 0 = 按下
    output reg  level,          // 去抖后电平, 1 = 按下
    output reg  press           // 按下瞬间单周期脉冲
);

    localparam integer MS_CNT = CLOCK_HZ / 1000;

    reg [15:0] ms_cnt;
    reg [7:0]  deb_cnt;
    reg [1:0]  sync;

    wire ms_tick  = (ms_cnt == MS_CNT - 1) && (MS_CNT > 1);
    wire in_press = ~sync[1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ms_cnt  <= 16'd0;
            deb_cnt <= 8'd0;
            sync    <= 2'b11;
            level   <= 1'b0;
            press   <= 1'b0;
        end else begin
            ms_cnt <= ms_tick ? 16'd0 : (ms_cnt + 1'b1);
            sync   <= {sync[0], btn_n};
            press  <= 1'b0;

            if (in_press == level) begin
                deb_cnt <= 8'd0;                 // 已稳定, 清零
            end else if (ms_tick) begin
                if (deb_cnt >= MS[7:0] - 1'b1) begin
                    deb_cnt <= 8'd0;
                    level   <= in_press;
                    if (in_press) press <= 1'b1;
                end else begin
                    deb_cnt <= deb_cnt + 1'b1;
                end
            end
        end
    end

endmodule
