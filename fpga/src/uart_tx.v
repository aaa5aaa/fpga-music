//=============================================================================
// uart_tx.v — 115200 8N1 串口发送
//=============================================================================
`timescale 1ns/1ps

module uart_tx #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD   = 115200
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,      // 单周期脉冲
    input  wire [7:0] data,
    output reg        tx,
    output reg        busy
);

    localparam integer BIT_TICKS = CLK_HZ / BAUD;

    reg [15:0] tick;
    reg [3:0]  bit_i;
    reg [9:0]  sh;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx    <= 1'b1;
            busy  <= 1'b0;
            tick  <= 16'd0;
            bit_i <= 4'd0;
            sh    <= 10'h3FF;
        end else if (!busy) begin
            tx <= 1'b1;
            if (start) begin
                sh    <= {1'b1, data, 1'b0};   // 停止位 + 数据 + 起始位
                tx    <= 1'b0;
                busy  <= 1'b1;
                bit_i <= 4'd0;
                tick  <= BIT_TICKS - 1;
            end
        end else if (tick != 16'd0) begin
            tick <= tick - 1'b1;
        end else if (bit_i == 4'd9) begin
            busy <= 1'b0;
            tx   <= 1'b1;
        end else begin
            tx    <= sh[1];
            sh    <= {1'b1, sh[9:1]};
            bit_i <= bit_i + 1'b1;
            tick  <= BIT_TICKS - 1;
        end
    end

endmodule
