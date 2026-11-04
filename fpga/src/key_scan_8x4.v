//=============================================================================
// key_scan_8x4.v — 8 行 x 4 列 矩阵键盘扫描 (32 键)
//
//   驱动 4 根列线(低有效扫描), 读取 8 根行线(内部上拉);
//   每列 125us, 4 列一轮 500us, 连续 2 轮(1ms)一致才更新 -> 去抖 1ms.
//   pressed[31:0]: bit = col*8 + row, 1 = 按下
//
//   注意: 为了让"驱动侧/读取侧"与接线无关, 这里固定由 FPGA 驱动列、读行;
//         矩阵键盘两侧都是纯开关, 交换驱动方向也能工作.
//=============================================================================
`timescale 1ns/1ps

module key_scan_8x4 #(
    parameter CLOCK_HZ = 50_000_000
)(
    input  wire        clk,
    input  wire        rst_n,
    output wire [3:0]  columns,     // 列驱动, 低有效
    input  wire [7:0]  rows,        // 行输入, 无键按下为高
    output reg  [31:0] pressed      // 稳定键位图
);

    localparam integer SCAN_TICKS = CLOCK_HZ / 8000;   // 125us

    reg [31:0] timer;
    reg [1:0]  col;
    reg [31:0] raw_frame;
    reg        frame_done;
    reg        frame_chk;          // frame_done 打一拍, 等 raw_frame 写全

    assign columns = ~(4'b0001 << col);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            timer      <= 32'd0;
            col        <= 2'd0;
            raw_frame  <= 32'd0;
            frame_done <= 1'b0;
            frame_chk  <= 1'b0;
        end else begin
            frame_chk <= frame_done;
            if (timer >= SCAN_TICKS - 1) begin
                timer <= 32'd0;
                // 本列已稳定驱动 125us, 采样本列 8 行 (低有效 -> 取反)
                raw_frame[{col, 3'b000} +: 8] <= ~rows;
                if (col == 2'd3) begin
                    col        <= 2'd0;
                    frame_done <= 1'b1;
                end else begin
                    col        <= col + 1'b1;
                    frame_done <= 1'b0;
                end
            end else begin
                timer      <= timer + 1'b1;
                frame_done <= 1'b0;
            end
        end
    end

    //-------------------------------------------------------------------------
    // 逐键去抖: 连续 2 轮(1ms)与当前状态不一致才翻转
    //-------------------------------------------------------------------------
    genvar i;
    generate
        for (i = 0; i < 32; i = i + 1) begin : g_deb
            reg [1:0] cnt;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    cnt        <= 2'd0;
                    pressed[i] <= 1'b0;
                end else if (frame_chk) begin
                    if (raw_frame[i] == pressed[i]) begin
                        cnt <= 2'd0;
                    end else if (cnt == 2'd1) begin
                        cnt        <= 2'd0;
                        pressed[i] <= raw_frame[i];
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end
            end
        end
    endgenerate

endmodule
