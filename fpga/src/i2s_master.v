//=============================================================================
// i2s_master.v — FPGA 作为 I2S 主机 (codec 配成从模式)
//
//   全部时钟由 50MHz 直接分频产生, 不依赖 PLL, 也不依赖 codec 输出时钟:
//       MCLK = 50MHz / 4      = 12.5      MHz
//       BCLK = 50MHz / 16     = 3.125     MHz
//       LRCK = BCLK / 64      = 48.828125 kHz   (MCLK / LRCK = 256 ✔)
//
//   帧格式 (Philips I2S):
//       每个 LRCK 周期 64 个 BCLK, 低电平 32 个 = 左声道, 高电平 32 个 = 右声道
//       数据在 BCLK 下降沿更新, LRCK 跳变后第 2 个上升沿开始是 MSB
//       16bit 数据 + 16bit 填充
//=============================================================================
`timescale 1ns/1ps

module i2s_master #(
    parameter integer CLK_HZ = 50_000_000
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [15:0] sample_l,
    input  wire [15:0] sample_r,

    output wire        mclk,
    output reg         bclk,
    output reg         lrck,
    output reg         dacdat,
    output reg         sample_tick      // 每帧一个 clk 脉冲 (帧首 = 左声道起点)
);

    //---- MCLK = clk/4 = 12.5MHz ------------------------------------------
    reg [1:0] mc;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) mc <= 2'd0;
        else        mc <= mc + 1'b1;
    assign mclk = mc[1];

    //---- BCLK = clk/16 = 3.125MHz ----------------------------------------
    reg [3:0] bc;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) bc <= 4'd0;
        else        bc <= bc + 1'b1;

    //---- 位序列机 --------------------------------------------------------
    reg [5:0]  bi;
    reg [15:0] sh;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bclk        <= 1'b0;
            lrck        <= 1'b0;
            dacdat      <= 1'b0;
            bi          <= 6'd0;
            sh          <= 16'd0;
            sample_tick <= 1'b0;
        end else begin
            bclk        <= bc[3];          // bc 0..7 低, 8..15 高
            sample_tick <= 1'b0;
            // bc==0 时 bclk 由 1 变 0 (下降沿), 在此更新数据
            if (bc == 4'd0) begin
                case (bi)
                // 左声道起点: LRCK 拉低, 送出 1 bit 填充 0, 锁存左样本
                6'd0: begin
                    lrck        <= 1'b0;
                    sh          <= sample_l;
                    dacdat      <= 1'b0;
                    sample_tick <= 1'b1;
                end
                // 左声道数据 16bit
                6'd1, 6'd2, 6'd3, 6'd4, 6'd5, 6'd6, 6'd7, 6'd8,
                6'd9, 6'd10, 6'd11, 6'd12, 6'd13, 6'd14, 6'd15, 6'd16: begin
                    dacdat <= sh[15];
                    sh     <= {sh[14:0], 1'b0};
                end
                // 右声道起点
                6'd32: begin
                    lrck   <= 1'b1;
                    sh     <= sample_r;
                    dacdat <= 1'b0;
                end
                // 右声道数据 16bit
                6'd33, 6'd34, 6'd35, 6'd36, 6'd37, 6'd38, 6'd39, 6'd40,
                6'd41, 6'd42, 6'd43, 6'd44, 6'd45, 6'd46, 6'd47, 6'd48: begin
                    dacdat <= sh[15];
                    sh     <= {sh[14:0], 1'b0};
                end
                default: dacdat <= 1'b0;   // 填充位
                endcase

                bi <= (bi == 6'd63) ? 6'd0 : (bi + 1'b1);
            end
        end
    end

endmodule
