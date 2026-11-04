//=============================================================================
// seg7_595.v — 74HC595 8 位数码管正式驱动
//
//   实测结论 (探测模块第 2 组):
//     段码低有效, 位选高有效, 先移段码后移位选
//     位选 bit0 = 最右一位, bit7 = 最左一位
//
//   显示 (左侧 4 位):
//     位1 = 't'
//     位2 = 音色 1=钢琴、2=古筝、3=箫
//     位3 = 音量十位 0..1
//     位4 = 音量个位 0..9
//   例: "t 1 1 3" 表示钢琴, 音量 13
//
//   刷新: 每位 1ms, 4 位共 4ms (~250Hz), 段码低有效/位选高有效
//=============================================================================
`timescale 1ns/1ps

module seg7_595 (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [1:0] timbre,
    input  wire [4:0] vol,
    input  wire [7:0] vel_disp,   // 实时力度 0..255
    input  wire [23:0] flash_id,  // W25Q64 JEDEC ID
    input  wire        flash_pass,
    input  wire        flash_fail,
    output reg        seg_dio,
    output reg        seg_sclk,
    output reg        seg_rclk
);

    localparam [15:0] HOLD = 16'd49_999;      // 1ms 每位
    localparam [5:0]  HALF = 6'd24;           // 1MHz 移位

    localparam [1:0] S_IDLE  = 2'd0,
                     S_SHIFT = 2'd1,
                     S_LATCH = 2'd2;

    reg [15:0] hold_cnt;
    reg [4:0]  bit_i;
    reg [5:0]  div;
    reg [1:0]  st;
    reg [2:0]  scan;

    // 7 段字符: bit0=a ... bit6=g, bit7=dp (高有效编码)
    function [7:0] seg_code;
        input [3:0] d;
        begin
            case (d)
                4'd0: seg_code = 8'h3F;
                4'd1: seg_code = 8'h06;
                4'd2: seg_code = 8'h5B;
                4'd3: seg_code = 8'h4F;
                4'd4: seg_code = 8'h66;
                4'd5: seg_code = 8'h6D;
                4'd6: seg_code = 8'h7D;
                4'd7: seg_code = 8'h07;
                4'd8: seg_code = 8'h7F;
                4'd9: seg_code = 8'h6F;
                4'd10: seg_code = 8'h77;   // A
                4'd11: seg_code = 8'h7C;   // b
                4'd12: seg_code = 8'h39;   // C
                4'd13: seg_code = 8'h5E;   // d
                4'd14: seg_code = 8'h79;   // E
                4'd15: seg_code = 8'h71;   // F
                default: seg_code = 8'h00;
            endcase
        end
    endfunction

    // 音量 0..19：不用除法，直接比较/减法，避免 vol -> 数码管的长组合路径
    wire [3:0] vol_tens = (vol >= 8'd10) ? 4'd1 : 4'd0;
    wire [5:0] vol_ones_w = vol - (vol_tens ? 6'd10 : 6'd0);
    wire [3:0] vol_ones = vol_ones_w[3:0];

    // 力度 0..255 -> 百分比 0..99
    //   100/255 ≈ 25/64，乘法+移位代替除法；两级寄存器避免长组合路径
    reg [6:0] pct_r;
    reg [3:0] pct_t, pct_o;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pct_r <= 7'd0;
            pct_t <= 4'd0;
            pct_o <= 4'd0;
        end else begin
            pct_r <= (vel_disp * 16'd25) >> 6;
            // 十位: 比较器, 不用除法器
            // (原来 /10 和 *10 串成 23ns, 把 Fmax 拉到 48MHz)
            if      (pct_r >= 7'd90) pct_t <= 4'd9;
            else if (pct_r >= 7'd80) pct_t <= 4'd8;
            else if (pct_r >= 7'd70) pct_t <= 4'd7;
            else if (pct_r >= 7'd60) pct_t <= 4'd6;
            else if (pct_r >= 7'd50) pct_t <= 4'd5;
            else if (pct_r >= 7'd40) pct_t <= 4'd4;
            else if (pct_r >= 7'd30) pct_t <= 4'd3;
            else if (pct_r >= 7'd20) pct_t <= 4'd2;
            else if (pct_r >= 7'd10) pct_t <= 4'd1;
            else                     pct_t <= 4'd0;

            // 个位: 用上一拍的十位 (×10 = ×8 + ×2, 移位相加, 无乘法器)
            // 与 pct_r 差一拍, 显示屏上看不出来
            if (pct_r >= {2'b00, pct_ten10}) pct_o <= pct_ones_w[3:0];
            else                             pct_o <= 4'd0;
        end
    end

    // ×10 = ×8 + ×2 (移位相加), 个位 = pct_r - 十位×10
    wire [4:0] pct_ten10  = {pct_t, 3'b000} + {pct_t, 1'b0};
    wire [6:0] pct_ones_w = pct_r - {2'b00, pct_ten10};

    // 自测完成后：先显示 PASS/FAIL 5 秒，再显示 ID 低 16 位 5 秒，然后恢复正常
    reg [28:0] status_hold;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) status_hold <= 29'd0;
        else if ((flash_pass || flash_fail) && status_hold < 29'd500_000_000)
            status_hold <= status_hold + 1'b1;
    end
    wire flash_done  = flash_pass || flash_fail;
    wire show_status = flash_done && (status_hold < 29'd250_000_000);
    wire show_id     = flash_done && (status_hold >= 29'd250_000_000) &&
                       (status_hold < 29'd500_000_000);

    reg [7:0] seg_char;
    always @(*) begin
        case (scan)
            3'd0:    seg_char = show_status ? (flash_pass ? 8'h73 : 8'h71) : 8'h78; // P/F 或 't'
            3'd1:    seg_char = show_status ? 8'h77 : seg_code({2'b00, timbre});    // A 或音色
            3'd2:    seg_char = show_status ? (flash_pass ? 8'h6D : 8'h06) : seg_code(vol_tens); // S/I
            3'd3:    seg_char = show_status ? (flash_pass ? 8'h6D : 8'h38) : seg_code(vol_ones); // S/L
            3'd4:    seg_char = show_status ? 8'h00 : (show_id ? seg_code(flash_id[15:12]) : 8'h7C); // 'b' = 弯音
            3'd5:    seg_char = show_status ? 8'h00 : (show_id ? seg_code(flash_id[11:8])  : seg_code(pct_t));
            3'd6:    seg_char = show_status ? 8'h00 : (show_id ? seg_code(flash_id[7:4])   : seg_code(pct_o));
            default: seg_char = show_status ? 8'h00 : (show_id ? seg_code(flash_id[3:0])   : 8'h00);
        endcase
    end

    wire [7:0]  seg_byte = ~seg_char;             // 段码低有效
    // 位选: 0..3 用左边 4 位 (bit7..bit4), 4..7 用右边 4 位 (bit3..bit0)
    wire [7:0]  dig_byte = (scan < 3'd4) ? (8'h80 >> scan[1:0]) : (8'h08 >> (scan - 3'd4));
    wire [15:0] word     = {seg_byte, dig_byte};  // 先段码, 后位选

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hold_cnt <= 16'd0;
            bit_i    <= 5'd0;
            div      <= 6'd0;
            st       <= S_IDLE;
            scan     <= 2'd0;
            seg_dio  <= 1'b0;
            seg_sclk <= 1'b0;
            seg_rclk <= 1'b0;
        end else begin
            case (st)
            //-----------------------------------------------------------------
            S_IDLE: begin
                seg_sclk <= 1'b0;
                seg_rclk <= 1'b0;
                if (hold_cnt >= HOLD) begin
                    hold_cnt <= 16'd0;
                    bit_i    <= 5'd15;
                    div      <= 6'd0;
                    seg_dio  <= word[15];
                    st       <= S_SHIFT;
                end else begin
                    hold_cnt <= hold_cnt + 1'b1;
                end
            end
            //-----------------------------------------------------------------
            S_SHIFT: begin
                if (div < HALF) begin
                    div <= div + 1'b1;
                end else if (div == HALF) begin
                    seg_sclk <= 1'b1;
                    div      <= HALF + 1'b1;
                end else if (div < 6'd49) begin
                    div <= div + 1'b1;
                end else begin
                    seg_sclk <= 1'b0;
                    div      <= 6'd0;
                    if (bit_i == 5'd0) begin
                        st <= S_LATCH;
                    end else begin
                        bit_i   <= bit_i - 1'b1;
                        seg_dio <= word[bit_i - 1'b1];
                    end
                end
            end
            //-----------------------------------------------------------------
            S_LATCH: begin
                seg_rclk <= 1'b1;
                if (div >= 6'd9) begin
                    seg_rclk <= 1'b0;
                    div      <= 6'd0;
                    scan     <= scan + 1'b1;      // 下一位
                    st       <= S_IDLE;
                end else begin
                    div <= div + 1'b1;
                end
            end
            //-----------------------------------------------------------------
            default: st <= S_IDLE;
            endcase
        end
    end

endmodule
