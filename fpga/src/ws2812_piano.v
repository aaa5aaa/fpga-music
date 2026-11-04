//=============================================================================
// ws2812_piano.v — WS2812B 灯带驱动: 按下哪个键, 对应那颗灯就亮(亮度随力度)
//
//   硬件: WS2812B, 5V 供电, 单线数据 (绿线), 数据格式 G-R-B 各 8 位
//   时序(50MHz): 1 位 = 62 拍(1.24us)
//                逻辑1 = 高 40 拍(0.80us) + 低 22 拍
//                逻辑0 = 高 20 拍(0.40us) + 低 42 拍
//   帧: N_LED x 24bit, 发送前先拉低 100us 复位
//
//   本版相对上一版的两处修改:
//
//   ① 时序: 原来 keys/vels 从扫描模块跨芯片路由过来, 直接进 32:1 选择器
//      + 8x8 乘法, 组合路径实测 23ns, 把 Fmax 压到 50.0MHz 边缘。
//      现在分三级流水:
//          A级: keys/vels/black_mask 本地寄存 (只走线, 无逻辑)
//          B级: 算颜色 + 乘亮度, 结果寄存
//          C级: 移位输出
//      每级路径都短, Fmax 余量恢复。
//
//   ② 功耗: 必须把整条灯带(N_LED 颗)全发一遍。只发前 32 颗的话, 后面
//      的灯收不到数据, 保持上电随机状态(常全白全亮), 电流可达 1.7A,
//      把板子 5V 拉垮。所以 N_LED=60, 只有前 N_KEY=32 颗参与按键映射。
//=============================================================================
`timescale 1ns/1ps

module ws2812_piano #(
    parameter integer N_LED  = 60,      // 整条灯带颗数
    parameter integer N_KEY  = 32,      // 按键数(用前 N_KEY 颗)
    parameter integer CLK_HZ = 50_000_000
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0]  keys,       // 32 个键, 1 = 按下
    input  wire [255:0] vels,       // 32 个力度, 每音 8 位
    input  wire [31:0]  black_mask, // 1 = 黑键
    input  wire [23:0]  color_white,// 白键颜色 {G,R,B}
    input  wire [23:0]  color_black,// 黑键颜色 {G,R,B}
    output reg         dout         // 接灯带 DATA(绿线)
);

    localparam integer TBIT = 62;    // 1 位 = 62 拍 = 1.24us
    localparam integer T0H  = 20;
    localparam integer T1H  = 40;
    localparam integer TRST = 5000;  // 复位低电平 100us

    //=========================================================================
    // A 级流水: 输入本地寄存 (切断跨芯片长走线)
    //=========================================================================
    reg [31:0]  keys_r;
    reg [255:0] vels_r;
    reg [31:0]  black_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            keys_r  <= 32'd0;
            vels_r  <= 256'd0;
            black_r <= 32'd0;
        end else begin
            keys_r  <= keys;
            vels_r  <= vels;
            black_r <= black_mask;
        end
    end

    //=========================================================================
    // 灯序号
    //=========================================================================
    reg [5:0]  ph;
    reg [5:0]  led;
    reg [4:0]  bitn;
    reg [23:0] sh;
    reg [15:0] rst_cnt;
    reg        sending;

    wire [5:0] led_nx = led + 6'd1;

    // 只有前 N_KEY 颗参与按键映射, 其余全黑
    wire        in_key  = (led    < N_KEY);
    wire        in_key_n= (led_nx < N_KEY);

    //=========================================================================
    // B 级流水: 算颜色 (含力度亮度), 结果寄存
    //   led 在整个 62 拍窗口内不变, 所以寄存一拍不影响结果
    //=========================================================================
    reg [23:0] col_now_r;
    reg [23:0] col_nx_r;

    // ---- B1 级: 先把力度选出来 (32:1 字节选择单独占一级) ----
    reg [7:0] v_now_r, v_nx_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_now_r <= 8'd0;
            v_nx_r  <= 8'd0;
        end else begin
            v_now_r <= vels_r[{led[4:0],    3'b000} +: 8];
            v_nx_r  <= vels_r[{led_nx[4:0], 3'b000} +: 8];
        end
    end

    // ---- 当前灯 ----
    wire [7:0]  v_now    = v_now_r;
    wire [15:0] vm_now   = {8'd0, v_now} * 16'd224;
    wire [7:0]  bri_now  = 8'd32 + vm_now[15:8];
    wire [23:0] base_now = black_r[led[4:0]] ? color_black : color_white;
    wire [15:0] nG = {8'd0, base_now[23:16]} * {8'd0, bri_now};
    wire [15:0] nR = {8'd0, base_now[15:8]}  * {8'd0, bri_now};
    wire [15:0] nB = {8'd0, base_now[7:0]}   * {8'd0, bri_now};
    wire [23:0] col_now_raw = (in_key && keys_r[led[4:0]]) ?
                              {nG[15:8], nR[15:8], nB[15:8]} : 24'd0;

    // ---- 下一颗灯 ----
    wire [7:0]  v_nx    = v_nx_r;
    wire [15:0] vm_nx   = {8'd0, v_nx} * 16'd224;
    wire [7:0]  bri_nx  = 8'd32 + vm_nx[15:8];
    wire [23:0] base_nx = black_r[led_nx[4:0]] ? color_black : color_white;
    wire [15:0] xG = {8'd0, base_nx[23:16]} * {8'd0, bri_nx};
    wire [15:0] xR = {8'd0, base_nx[15:8]}  * {8'd0, bri_nx};
    wire [15:0] xB = {8'd0, base_nx[7:0]}   * {8'd0, bri_nx};
    wire [23:0] col_nx_raw = (in_key_n && keys_r[led_nx[4:0]]) ?
                             {xG[15:8], xR[15:8], xB[15:8]} : 24'd0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col_now_r <= 24'd0;
            col_nx_r  <= 24'd0;
        end else begin
            col_now_r <= col_now_raw;
            col_nx_r  <= col_nx_raw;
        end
    end

    //=========================================================================
    // C 级: 串行发送
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dout    <= 1'b0;
            ph      <= 6'd0;
            led     <= 6'd0;
            bitn    <= 5'd23;
            sh      <= 24'd0;
            rst_cnt <= 16'd0;
            sending <= 1'b0;
        end else if (!sending) begin
            //-------- 复位期: 拉低等够 100us, 然后开始发一帧 --------
            dout <= 1'b0;
            ph   <= 6'd0;
            if (rst_cnt + 1'b1 >= TRST) begin
                rst_cnt <= 16'd0;
                led     <= 6'd0;
                sh      <= col_now_r;
                bitn    <= 5'd23;
                sending <= 1'b1;
            end else begin
                rst_cnt <= rst_cnt + 1'b1;
            end
        end else begin
            //-------- 发送期 --------
            dout <= (ph < (sh[23] ? T1H : T0H)) ? 1'b1 : 1'b0;

            if (ph == TBIT - 1) begin
                ph <= 6'd0;
                if (bitn == 5'd0) begin
                    // 一颗灯发完
                    sh   <= col_nx_r;
                    bitn <= 5'd23;
                    if (led == N_LED - 1) begin
                        sending <= 1'b0;      // 整条灯带发完, 回复位期
                        led     <= 6'd0;
                    end else begin
                        led <= led_nx;
                    end
                end else begin
                    bitn <= bitn - 1'b1;
                    sh   <= {sh[22:0], 1'b0};
                end
            end else begin
                ph <= ph + 1'b1;
            end
        end
    end

endmodule
