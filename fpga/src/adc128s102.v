//=============================================================================
// adc128s102.v — 8 通道 12bit SPI ADC 驱动 (连续转换, 单通道轮询)
//   SCLK = CLK_HZ / (DIV*2), 100MHz / DIV=4 -> 12.5MHz (手册 8~16MHz)
//   帧: CS 低 -> 16 个 SCLK, 前 8 个 DIN 送通道字, 第 5..16 个上升沿取 12bit
//=============================================================================
`timescale 1ns/1ps

module adc128s102 #(
    parameter CLK_HZ = 100_000_000,
    parameter DIV    = 4
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [2:0]  channel,
    output reg  [11:0] data,
    output reg         data_vld,
    output reg         adc_sclk,
    output reg         adc_cs_n,
    output reg         adc_din,
    input  wire        adc_dout
);

    localparam GAP = 16'd500;      // 两次转换之间留 5us

    reg [7:0]  div_cnt;
    reg        sclk2x;
    reg [5:0]  seq;
    reg [11:0] r_data;
    reg        en;
    reg [2:0]  ch_r;
    reg [15:0] gap_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            en       <= 1'b0;
            div_cnt  <= 8'd0;
            sclk2x   <= 1'b0;
            seq      <= 6'd0;
            r_data   <= 12'd0;
            data     <= 12'd0;
            data_vld <= 1'b0;
            adc_sclk <= 1'b1;
            adc_cs_n <= 1'b1;
            adc_din  <= 1'b1;
            ch_r     <= 3'd0;
            gap_cnt  <= 16'd0;
        end else begin
            data_vld <= 1'b0;

            // ---- 分频产生 2x SCLK 节拍 ----
            if (en) begin
                if (div_cnt == DIV-1) div_cnt <= 8'd0;
                else                  div_cnt <= div_cnt + 1'b1;
            end else begin
                div_cnt <= 8'd0;
            end
            sclk2x <= (en && (div_cnt == DIV-1));

            // ---- 序列机 ----
            if (!en) begin
                adc_cs_n <= 1'b1;
                adc_sclk <= 1'b1;
                seq      <= 6'd0;
                gap_cnt  <= gap_cnt + 1'b1;
                if (gap_cnt >= GAP) begin
                    gap_cnt <= 16'd0;
                    ch_r    <= channel;
                    en      <= 1'b1;
                end
            end else if (sclk2x) begin
                case (seq)
                6'd0:  adc_cs_n <= 1'b0;
                6'd1:  begin adc_sclk <= 1'b0; adc_din <= 1'b0; end
                6'd2:  adc_sclk <= 1'b1;
                6'd3:  adc_sclk <= 1'b0;
                6'd4:  adc_sclk <= 1'b1;
                6'd5:  begin adc_sclk <= 1'b0; adc_din <= ch_r[2]; end
                6'd6:  adc_sclk <= 1'b1;
                6'd7:  begin adc_sclk <= 1'b0; adc_din <= ch_r[1]; end
                6'd8:  adc_sclk <= 1'b1;
                6'd9:  begin adc_sclk <= 1'b0; adc_din <= ch_r[0]; end
                6'd10: begin adc_sclk <= 1'b1; r_data <= {r_data[10:0], adc_dout}; end
                6'd11: adc_sclk <= 1'b0;
                6'd12: begin adc_sclk <= 1'b1; r_data <= {r_data[10:0], adc_dout}; end
                6'd13: adc_sclk <= 1'b0;
                6'd14: begin adc_sclk <= 1'b1; r_data <= {r_data[10:0], adc_dout}; end
                6'd15: adc_sclk <= 1'b0;
                6'd16: begin adc_sclk <= 1'b1; r_data <= {r_data[10:0], adc_dout}; end
                6'd17: adc_sclk <= 1'b0;
                6'd18: begin adc_sclk <= 1'b1; r_data <= {r_data[10:0], adc_dout}; end
                6'd19: adc_sclk <= 1'b0;
                6'd20: begin adc_sclk <= 1'b1; r_data <= {r_data[10:0], adc_dout}; end
                6'd21: adc_sclk <= 1'b0;
                6'd22: begin adc_sclk <= 1'b1; r_data <= {r_data[10:0], adc_dout}; end
                6'd23: adc_sclk <= 1'b0;
                6'd24: begin adc_sclk <= 1'b1; r_data <= {r_data[10:0], adc_dout}; end
                6'd25: adc_sclk <= 1'b0;
                6'd26: begin adc_sclk <= 1'b1; r_data <= {r_data[10:0], adc_dout}; end
                6'd27: adc_sclk <= 1'b0;
                6'd28: begin adc_sclk <= 1'b1; r_data <= {r_data[10:0], adc_dout}; end
                6'd29: adc_sclk <= 1'b0;
                6'd30: begin adc_sclk <= 1'b1; r_data <= {r_data[10:0], adc_dout}; end
                6'd31: adc_sclk <= 1'b0;
                6'd32: begin adc_sclk <= 1'b1; r_data <= {r_data[10:0], adc_dout}; end
                6'd33: begin
                    adc_cs_n <= 1'b1;
                    data     <= r_data;
                    data_vld <= 1'b1;
                    en       <= 1'b0;
                    gap_cnt  <= 16'd0;
                end
                default: adc_cs_n <= 1'b1;
                endcase
                if (seq < 6'd33) seq <= seq + 1'b1;
            end
        end
    end

endmodule
