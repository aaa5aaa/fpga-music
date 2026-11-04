`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// ES8388 寄存器初始化表
//
// 本表取自 小梅哥 ch35_Audio_loopback 工程(该表在本板已实测能出声), 只做 3 处修改:
//
//   rom[6]  0x08: 0x84 -> 0x85   BCLKDIV 从 MCLK/4 改为 MCLK/6
//                                原因: 手册 Table 2 中 16kHz(MCLK/768) 这一行规定
//                                SCLK = MCLK/6 -> 2.047MHz -> 128 BCLK/帧;
//                                用 MCLK/4 会变成 192 BCLK/帧, 与 DAC 串口不匹配.
//   rom[8]  0x0D: 0x04 -> 0x06   LRCK = MCLK/768 = 15.99kHz (原 0x04 = /512)
//   rom[9]  0x18: 0x04 -> 0x06   DAC 同频, 与 ADC 共用 LRCK
//   rom[33] 0x04: 0x36 -> 0x3C   LOUT1/ROUT1/LOUT2/ROUT2 全部打开
//
//  MCLK = 50MHz x 14 / 57 = 12.2807MHz
//////////////////////////////////////////////////////////////////////////////////


module ES8388_init_table#(
    parameter DATA_WIDTH=16, 
    parameter ADDR_WIDTH=8
)(
	input [(ADDR_WIDTH-1):0] addr,
	input clk, 
	output reg [(DATA_WIDTH-1):0] q,
	output [7:0]dev_id,
	output [7:0]lut_size
);

	reg [DATA_WIDTH-1:0] rom[2**ADDR_WIDTH-1:0];
	integer fill_i;
	
	assign dev_id = 8'h20;		// ES8388 IIC 器件地址 (7bit 0x10)
	assign lut_size = 8'd43;	// 寄存器初始化数量

	always @ (*) begin
		// 未用到的表项清零, 避免 "does not have a driver" 告警
		for (fill_i = 0; fill_i < 2**ADDR_WIDTH; fill_i = fill_i + 1)
			rom[fill_i] = 16'h0000;

		rom[0 ] = 16'h01_58;
		rom[1 ] = 16'h01_50;
		rom[2 ] = 16'h02_F3;
		rom[3 ] = 16'h02_F0;
		rom[4 ] = 16'h2B_80;  // ALRCK/DLRCK 共用一路 LRCK
		rom[5 ] = 16'h00_36;
		rom[6 ] = 16'h08_00;  // 从模式 (MSC=0): BCLK/LRCK 由 FPGA 提供
		rom[7 ] = 16'h04_00;
		rom[8 ] = 16'h0D_02;  // 从模式下被忽略, 填 256 只为一致性
		rom[9 ] = 16'h18_02;  // 同上
		rom[10] = 16'h05_00;
		rom[11] = 16'h06_C3;
		rom[12] = 16'h0A_00;
		rom[13] = 16'h0B_02;
		rom[14] = 16'h0C_0C;  // ADC: I2S, 16bit
		rom[15] = 16'h17_18;  // DAC: I2S, 16bit
		rom[16] = 16'h10_00;
		rom[17] = 16'h11_00;
		rom[18] = 16'h1A_00;  // LDACVOL = 0x00 = 0dB (手册: 0x00=0dB, 0xC0=-96dB)
		rom[19] = 16'h1B_00;  // RDACVOL = 0x00 = 0dB
		rom[20] = 16'h09_00;
		rom[21] = 16'h12_E2;
		rom[22] = 16'h13_C0;
		rom[23] = 16'h14_12;
		rom[24] = 16'h15_06;
		rom[25] = 16'h16_C3;
		rom[26] = 16'h27_B8;  // LD2LO = 1: DAC 左声道接进输出混音
		rom[27] = 16'h2A_B8;  // RD2RO = 1: DAC 右声道接进输出混音
		rom[28] = 16'h02_00;  // 全上电 (此后延时 500ms)
		rom[29] = 16'h2E_1E;  // LOUT1 音量 0dB
		rom[30] = 16'h2F_1E;  // ROUT1 音量 0dB
		rom[31] = 16'h30_1E;  // LOUT2 音量 0dB
		rom[32] = 16'h31_1E;  // ROUT2 音量 0dB
		rom[33] = 16'h04_3C;  // LOUT1/ROUT1/LOUT2/ROUT2 全开
		rom[34] = 16'h26_00;
		rom[35] = 16'h03_09;
		rom[36] = 16'h2E_1E;
		rom[37] = 16'h2F_1E;
		rom[38] = 16'h30_1E;
		rom[39] = 16'h31_1E;
		rom[40] = 16'h32_00;  // shelving 系数 (高音/低音滤波)
		rom[41] = 16'h33_AA;
		rom[42] = 16'h34_AA;
	end

	always @ (posedge clk)
	begin
		q <= rom[addr];
	end
endmodule
