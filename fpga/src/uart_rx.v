//=============================================================================
// uart_rx.v — 115200 8N1 串口接收 (16 倍过采样近似：中点采样)
//
//   50MHz / 115200 = 434.03 -> 每 bit 434 个时钟，误差 0.007%
//   起始位中点对齐，之后每 434 个时钟采一位，停止位检查高电平
//=============================================================================
`timescale 1ns/1ps

module uart_rx #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD   = 115200
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx,
    output reg  [7:0] data,
    output reg        valid
);

    localparam integer BIT_TICKS = CLK_HZ / BAUD;
    localparam integer HALF      = BIT_TICKS / 2;

    reg [1:0]  sync;
    reg [15:0] tick;
    reg [3:0]  bit_i;
    reg [7:0]  sh;
    reg        busy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sync  <= 2'b11;
            tick  <= 16'd0;
            bit_i <= 4'd0;
            sh    <= 8'd0;
            busy  <= 1'b0;
            data  <= 8'd0;
            valid <= 1'b0;
        end else begin
            sync  <= {sync[0], rx};
            valid <= 1'b0;

            if (!busy) begin
                if (!sync[1]) begin
                    busy  <= 1'b1;
                    tick  <= HALF;
                    bit_i <= 4'd0;
                end
            end else if (tick != 16'd0) begin
                tick <= tick - 1'b1;
            end else begin
                if (bit_i == 4'd0) begin
                    // 起始位中点仍为低才认为是真起始位
                    if (sync[1]) begin
                        busy <= 1'b0;
                    end else begin
                        tick  <= BIT_TICKS - 1;
                        bit_i <= 4'd1;
                    end
                end else if (bit_i <= 4'd8) begin
                    sh[bit_i - 1'b1] <= sync[1];
                    tick <= BIT_TICKS - 1;
                    bit_i <= bit_i + 1'b1;
                end else begin
                    // 停止位
                    if (sync[1]) begin
                        data  <= sh;
                        valid <= 1'b1;
                    end
                    busy <= 1'b0;
                end
            end
        end
    end

endmodule
