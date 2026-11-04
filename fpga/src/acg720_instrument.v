//=============================================================================
// acg720_instrument.v — ACG720 电子琴  v5
//
//  v5 关键改动: I2S 改为 FPGA 当主机
//    - 删掉 Gowin_PLL, MCLK 由 50MHz 直接 4 分频 = 12.5MHz
//    - BCLK = 3.125MHz, LRCK = 48.828kHz 全部由 FPGA 产生
//    - ES8388 配成从模式 (0x08 = 0x00), 不再依赖 codec 输出时钟
//    - 上电自动播放 3 秒测试音, 不用碰任何拨码就能验证"有没有声音"
//
//  LED:
//    D2(L21) = codec_ready      I2C 配通
//    D3(K21) = dacdat 在翻转    真的在发 I2S 数据
//    D4(K22) = 帧节拍在跳        合成引擎在被时钟驱动
//    D5(J22) = 32 路复音测试中 (SW6)
//    D6(H22) = 合成器有样本输出
//    D7(M21) = 1Hz 心跳
//=============================================================================
`timescale 1ns/1ps

module acg720_instrument (
    input  wire        clk_50m,
    input  wire        reset_n,
    output wire [3:0]  columns,
    input  wire [7:0]  rows,
    input  wire [7:0]  sw_n,
    input  wire [3:0]  func_btn_n,   // 外接 4 键模块: 颤音/滑音/合唱/延迟 (低有效)
    output wire [5:0]  leds,
    //---- WS2812B 灯带数据 (绿线) ----
    output wire        ws2812_din,
    inout  wire        codec_sda,
    output wire        codec_scl,
    output wire        codec_mclk,      // FPGA 输出 12.5MHz
    output wire        codec_bclk,      // FPGA 输出 3.125MHz
    output wire        codec_lrck,      // FPGA 输出 48.828kHz
    output wire        codec_dacdat,
    //---- 蓝牙模块 (ESP32-C3 BLE-UART) ----
    input  wire        bt_rx,
    output wire        bt_tx,
    input  wire        bt_state,
    //---- 板载 USB-UART (PC 调试/兜底) ----
    input  wire        dbg_rx,
    output wire        dbg_tx,
    //---- EC11 音量旋钮 ----
    input  wire        rot_a,
    input  wire        rot_b,
    input  wire        rot_sw,
    //---- 74HC595 8 位数码管 ----
    output wire        seg7_dio,
    output wire        seg7_sclk,
    output wire        seg7_rclk,
    input  wire        adc_dout,       // 板载 ADC128S102: 数据输出 (P6)
    output wire        adc_sclk,       // 板载 ADC128S102: 时钟 (N5)
    output wire        adc_cs_n,       // 板载 ADC128S102: 片选 (M6)
    output wire        adc_din,        // ADC128S102 data in (M5)
    //---- W25Q64 SPI Flash (ID 测试) ----
    output wire        flash_cs,
    output wire        flash_sclk,
    output wire        flash_mosi,
    input  wire        flash_miso,
    //---- LCD SPI (2.4" ILI9341) ----
    output wire        lcd_cs,
    output wire        lcd_rst,
    output wire        lcd_dc,
    output wire        lcd_mosi,
    output wire        lcd_sck,
    //---- 板载 S1: 四页显示切换 (A20) ----
    input  wire        key_s1,
    //---- 板载 S2: 播放/停止已存曲目 (B20) ----
    input  wire        key_s2,
    //---- 板载 S3: 录音开始/停止 (A21) ----
    input  wire        key_s3
);

    localparam integer N_VOICE = 32;

    //-------------------------------------------------------------------------
    // 复位同步
    //-------------------------------------------------------------------------
    reg rst_d0, rst_d1;
    always @(posedge clk_50m or negedge reset_n) begin
        if (!reset_n) begin
            rst_d0 <= 1'b0;
            rst_d1 <= 1'b0;
        end else begin
            rst_d0 <= 1'b1;
            rst_d1 <= rst_d0;
        end
    end
    wire rst_n = rst_d1;

    //-------------------------------------------------------------------------
    // 板载 S1 (A20): 四页显示切换 0=状态 1=示波器 2=李萨如 3=频谱
    //-------------------------------------------------------------------------
    wire s1_level, s1_press;
    btn_debounce #(.CLOCK_HZ(50_000_000), .MS(15)) u_s1_key (
        .clk   (clk_50m),
        .rst_n (rst_n),
        .btn_n (key_s1),
        .level (s1_level),
        .press (s1_press)
    );

    reg [2:0] ui_mode;
    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n)        ui_mode <= 3'd0;
        else if (s1_press) ui_mode <= (ui_mode == 3'd2) ? 3'd0 : ui_mode + 1'b1;
    end

    // 曲库页选中槽位 (EC11 选择, S2 加载播放)
    wire       rot_step, rot_dir;
    reg  [3:0] lib_sel;
    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) lib_sel <= 4'd0;
        else if (rot_step && ui_mode == 3'd2) begin
            if (rot_dir) lib_sel <= (lib_sel == 4'd15) ? 4'd0  : lib_sel + 1'b1;
            else         lib_sel <= (lib_sel == 4'd0)  ? 4'd15 : lib_sel - 1'b1;
        end
    end

    //-------------------------------------------------------------------------
    // 板载 S2 (B20): 播放/停止已存曲目
    //-------------------------------------------------------------------------
    wire s2_level, s2_key_press;
    btn_debounce #(.CLOCK_HZ(50_000_000), .MS(15)) u_s2_key (
        .clk   (clk_50m),
        .rst_n (rst_n),
        .btn_n (key_s2),
        .level (s2_level),
        .press (s2_key_press)
    );

    //-------------------------------------------------------------------------
    // 板载 S3 (A21): 按一下开始录音，再按一下停止并自动存槽
    //-------------------------------------------------------------------------
    wire s3_level, s3_press;
    btn_debounce #(.CLOCK_HZ(50_000_000), .MS(15)) u_s3_key (
        .clk   (clk_50m),
        .rst_n (rst_n),
        .btn_n (key_s3),
        .level (s3_level),
        .press (s3_press)
    );

    //-------------------------------------------------------------------------
    // I2S 主机
    //-------------------------------------------------------------------------
    wire        sample_tick;
    wire [15:0] dac_l, dac_r;

    i2s_master #(.CLK_HZ(50_000_000)) i2s (
        .clk        (clk_50m),
        .rst_n      (rst_n),
        .sample_l   (dac_l),
        .sample_r   (dac_r),
        .mclk       (codec_mclk),
        .bclk       (codec_bclk),
        .lrck       (codec_lrck),
        .dacdat     (codec_dacdat),
        .sample_tick(sample_tick)
    );

    //-------------------------------------------------------------------------
    // ES8388 配置 (从模式)
    //-------------------------------------------------------------------------
    wire codec_ready;

    ES8388_Init codec_setup (
        .Clk          (clk_50m),
        .Rst_n        (rst_n),
        .I2C_Init_Done(codec_ready),
        .i2c_sdat     (codec_sda),
        .i2c_sclk     (codec_scl)
    );

    //-------------------------------------------------------------------------
    // 键盘 / 拨码
    //-------------------------------------------------------------------------
    wire [31:0] keys;
    wire [31:0] physical_notes;
    wire [31:0] voice_gates;
    wire [7:0]  button_press;
    wire [31:0] active_voices;
    wire signed [15:0] voice_samples [0:N_VOICE-1];
    wire [255:0] voice_level;          // 32 声部包络电平 -> LCD
    reg  [7:0]   env_level;           // Latest-triggered voice ADSR -> LCD history
    wire [7:0]  voice_expression [0:N_VOICE-1];
    wire signed [15:0] processed_sample;

    //-------------------------------------------------------------------------
    // 蓝牙 / 串口曲库
    //   bt_rx/bt_tx : ESP32-C3 BLE-UART (D14/D15)
    //   dbg_rx/dbg_tx: 板载 USB-UART (J21/M15), 给 PC 调试/兜底
    //   两路接收共用一个协议解析器, 回复同时送到两个 TX 引脚
    //-------------------------------------------------------------------------
    wire [31:0]  song_gate;
    wire [31:0]  live_gate;
    wire signed [31:0] pitch_bend;
    wire [255:0] live_vel;
    wire [4:0]  pc_vol;
    wire        pc_vol_set;
    wire [1:0]  pc_timbre;
    wire        pc_timbre_set;
    wire [1:0]  pc_vib;
    wire        pc_vib_set;
    wire [1:0]  pc_glide;
    wire        pc_glide_set;
    wire        pc_chorus;
    wire        pc_chorus_set;
    wire        pc_delay;
    wire        pc_delay_set;
    reg  [1:0]  timbre;
    wire        chorus_on;
    wire        delay_on;
    reg  [7:0]  vel8_r;
    reg  [7:0]  disp_expr;
    wire [15:0] adsr_att, adsr_dec, adsr_sus, adsr_rel;
    wire [4:0]  vol;
    wire [9:0]  gain_q8;
    reg  [1:0]  vib_sel;
    reg  [1:0]  glide_sel;
    // ADSR 参数变化很慢，顶层打一拍再送到 32 个 voice，
    // 切断 bt_cmd 到各 voice 加减/乘法器的长路径。
    // ---- 音色默认包络 (PC 没下发时用这套) ----
    //   钢琴: A2ms  D1342ms S0    R300ms   (击弦, 长余音)
    //   古筝: A1ms  D1342ms S0    R300ms   (拨弦, 长余音)
    //   箫  : A120ms D224ms S0.85 R200ms   (吹管, 慢起音, 保持)
    localparam integer FS_P = 48828;
    localparam [15:0] P_FULL = 16'hFFFF, P_SUSX = 16'd55705;
    localparam [15:0] TA0 = P_FULL/((FS_P/1000)*2),   TD0 = P_FULL/((FS_P/1000)*1200), TR0 = P_FULL/((FS_P/1000)*300);
    localparam [15:0] TA1 = P_FULL/((FS_P/1000)*1),   TD1 = P_FULL/((FS_P/1000)*1200), TR1 = P_FULL/((FS_P/1000)*300);
    localparam [15:0] TA2 = P_FULL/((FS_P/1000)*120), TD2 = (P_FULL-P_SUSX)/((FS_P/1000)*200), TR2 = P_FULL/((FS_P/1000)*200);
    wire [15:0] tmpl_att = (timbre == 2'd2) ? TA1 : (timbre == 2'd3) ? TA2 : TA0;
    wire [15:0] tmpl_dec = (timbre == 2'd2) ? TD1 : (timbre == 2'd3) ? TD2 : TD0;
    wire [15:0] tmpl_rel = (timbre == 2'd2) ? TR1 : (timbre == 2'd3) ? TR2 : TR0;
    wire [15:0] tmpl_sus = (timbre == 2'd3) ? P_SUSX : 16'd0;
    // 上位机一旦下发过 ADSR, 就用上位机的
    wire pc_adsr_set = (adsr_att != TA0) || (adsr_dec != TD0) ||
                       (adsr_sus != 16'd0) || (adsr_rel != TR0);

    reg  [15:0] adsr_att_r, adsr_dec_r, adsr_sus_r, adsr_rel_r;
    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            adsr_att_r <= TA0;
            adsr_dec_r <= TD0;
            adsr_sus_r <= 16'd0;
            adsr_rel_r <= TR0;
        end else begin
            adsr_att_r <= pc_adsr_set ? adsr_att : tmpl_att;
            adsr_dec_r <= pc_adsr_set ? adsr_dec : tmpl_dec;
            adsr_sus_r <= pc_adsr_set ? adsr_sus : tmpl_sus;
            adsr_rel_r <= pc_adsr_set ? adsr_rel : tmpl_rel;
        end
    end
    wire [255:0] song_vel;
    wire [11:0]  song_pos;
    wire         song_playing;
    // M22/N22 是专用 SSPI 脚，不能当 LED；蓝牙状态复用 D6/D7
    wire         bt_link, bt_act;

    wire [7:0] bt_rx_data, dbg_rx_data;
    wire       bt_rx_valid, dbg_rx_valid;
    wire [7:0] proto_rx_data;
    wire       proto_rx_valid;
    wire [7:0] proto_tx_data;
    wire       proto_tx_start, proto_tx_busy, proto_tx_line;

    uart_rx #(.CLK_HZ(50_000_000), .BAUD(115200)) u_bt_rx (
        .clk   (clk_50m),
        .rst_n (rst_n),
        .rx    (bt_rx),
        .data  (bt_rx_data),
        .valid (bt_rx_valid)
    );

    uart_rx #(.CLK_HZ(50_000_000), .BAUD(115200)) u_dbg_rx (
        .clk   (clk_50m),
        .rst_n (rst_n),
        .rx    (dbg_rx),
        .data  (dbg_rx_data),
        .valid (dbg_rx_valid)
    );

    // 蓝牙优先；PC 调试口平时不发数据，不会抢
    assign proto_rx_data  = bt_rx_valid ? bt_rx_data : dbg_rx_data;
    assign proto_rx_valid = bt_rx_valid | dbg_rx_valid;

    uart_tx #(.CLK_HZ(50_000_000), .BAUD(115200)) u_tx (
        .clk   (clk_50m),
        .rst_n (rst_n),
        .start (proto_tx_start),
        .data  (proto_tx_data),
        .tx    (proto_tx_line),
        .busy  (proto_tx_busy)
    );

    assign bt_tx  = proto_tx_line;
    assign dbg_tx = proto_tx_line;

    wire         frame_valid;
    wire [7:0]   frame_cmd;
    wire [5:0]   frame_len;
    wire [511:0] frame_payload;
    wire         frame_ack;
    wire [11:0]  song_wr_addr;
    wire [31:0]  song_wr_data;
    wire         song_wr_en;
    wire [11:0]  song_len;
    wire         song_play, song_stop, song_pause;

    //---- Flash 曲库 ----
    wire         save_req, save_done, save_err;
    wire [3:0]   lib_slot;
    wire         load_req, load_done;
    wire         delete_req, delete_done;
    wire [11:0]  fs_wr_addr;
    wire [31:0]  fs_wr_data;
    wire         fs_wr_en;
    wire [11:0]  fs_song_len;
    wire         fs_load_active;
    wire [11:0]  ext_addr;
    wire [31:0]  ext_data;
    wire         ext_en;

    // 写口仲裁: 上电加载 > 录音 > 蓝牙下载
    wire [11:0]  rec_wr_addr;
    wire [31:0]  rec_wr_data;
    wire         rec_wr_en;
    wire [11:0]  rec_len;
    wire         rec_active, rec_done, rec_full;
    wire         rec_clear;
    wire [11:0]  fs_cur_len;
    wire         fs_save_req;
    wire [3:0]   fs_slot_sel;
    wire [127:0] fs_save_name;
    wire         fs_save_busy, fs_load_busy;
    wire [11:0]  sram_wr_addr = fs_load_active ? fs_wr_addr :
                                (rec_active ? rec_wr_addr : song_wr_addr);
    wire [31:0]  sram_wr_data = fs_load_active ? fs_wr_data :
                                (rec_active ? rec_wr_data : song_wr_data);
    wire         sram_wr_en   = fs_load_active ? fs_wr_en :
                                (rec_active ? rec_wr_en : song_wr_en);

    // 曲目长度: 录音完成后优先用录音长度
    wire [11:0]  eff_len      = rec_done ? rec_len :
                                ((song_len != 12'd0) ? song_len : fs_song_len);
    wire [11:0]  sram_song_len= fs_load_active ? fs_song_len : eff_len;
    wire [15:0]  lib_mask;
    wire [3:0]   lib_current;
    wire [127:0] save_name;
    wire         name_req;
    wire [3:0]   name_slot;
    wire         name_done;
    wire [127:0] name_data;
    wire         name_valid;
    wire         bt_rec_clear;
    wire         bt_rec_cmd;
    wire [3:0]   bt_rec_slot;
    reg          rec_done_d, rec_save_req;
    reg  [3:0]   rec_target;

    // 自动保存到 S3 录音时选中的槽位；名字固定为“录音”
    wire [127:0] REC_NAME = {80'd0, 8'hB3, 8'h9F, 8'hE9, 8'h95, 8'hBD, 8'hE5};
    assign rec_clear   = bt_rec_clear | load_req;
    assign fs_save_req = save_req | rec_save_req;
    assign fs_slot_sel = rec_save_req ? rec_target : lib_slot;
    assign fs_save_name= rec_save_req ? REC_NAME : save_name;
    assign fs_cur_len  = rec_done ? rec_len : eff_len;

    bt_rx_frame u_bt_rx_frame (
        .clk           (clk_50m),
        .rst_n         (rst_n),
        .rx_data       (proto_rx_data),
        .rx_valid      (proto_rx_valid),
        .frame_valid   (frame_valid),
        .frame_cmd     (frame_cmd),
        .frame_len     (frame_len),
        .frame_payload (frame_payload),
        .frame_ack     (frame_ack)
    );

    bt_cmd u_bt_cmd (
        .clk           (clk_50m),
        .rst_n         (rst_n),
        .frame_valid   (frame_valid),
        .frame_cmd     (frame_cmd),
        .frame_len     (frame_len),
        .frame_payload (frame_payload),
        .frame_ack     (frame_ack),
        .song_wr_addr  (song_wr_addr),
        .song_wr_data  (song_wr_data),
        .song_wr_en    (song_wr_en),
        .song_len      (song_len),
        .song_play     (song_play),
        .song_stop     (song_stop),
        .song_pause    (song_pause),
        .song_pos      (song_pos),
        .song_playing  (song_playing),
        .tx_data       (proto_tx_data),
        .tx_start      (proto_tx_start),
        .tx_busy       (proto_tx_busy),
        .bt_state      (bt_state),
        .led_link      (bt_link),
        .led_act       (bt_act),
        .save_req      (save_req),
        .save_done     (save_done),
        .save_err      (save_err),
        .slot_sel      (lib_slot),
        .load_req      (load_req),
        .load_done     (load_done),
        .delete_req    (delete_req),
        .delete_done   (delete_done),
        .ext_len       (eff_len),
        .lib_mask      (lib_mask),
        .lib_current   (lib_current),
        .play_key      (s2_key_press && (ui_mode != 3'd2) && !rec_active),
        .lib_play      (s2_key_press && (ui_mode == 3'd2) && !rec_active),
        .lib_slot      (lib_sel),
        .rec_clear     (bt_rec_clear),
        .rec_active    (rec_active),
        .rec_len       (rec_len),
        .rec_full      (rec_full),
        .keys          (keys),
        .vel8          (vel8_r),
        .vol           (vol[4:0]),
        .timbre        (timbre),
        .vib_sel       (vib_sel),
        .glide_sel     (glide_sel),
        .chorus_on     (chorus_on),
        .delay_on      (delay_on),
        .sample_tick   (sample_tick),
        .scope_audio   (processed_sample),
        .rec_cmd       (bt_rec_cmd),
        .rec_slot      (bt_rec_slot),
        .live_gate     (live_gate),
        .live_vel      (live_vel),
        .pitch_bend    (pitch_bend),
        .pc_vol        (pc_vol),
        .pc_vol_set    (pc_vol_set),
        .pc_timbre     (pc_timbre),
        .pc_timbre_set (pc_timbre_set),
        .pc_vib        (pc_vib),
        .pc_vib_set    (pc_vib_set),
        .pc_glide      (pc_glide),
        .pc_glide_set  (pc_glide_set),
        .pc_chorus     (pc_chorus),
        .pc_chorus_set (pc_chorus_set),
        .pc_delay      (pc_delay),
        .pc_delay_set  (pc_delay_set),
        .adsr_att      (adsr_att),
        .adsr_dec      (adsr_dec),
        .adsr_sus      (adsr_sus),
        .adsr_rel      (adsr_rel),
        .save_name     (save_name),
        .name_req      (name_req),
        .name_slot     (name_slot),
        .name_done     (name_done),
        .name_data     (name_data),
        .name_valid    (name_valid)
    );

    song_engine u_song_engine (
        .clk      (clk_50m),
        .rst_n    (rst_n),
        .wr_en    (sram_wr_en),
        .wr_addr  (sram_wr_addr),
        .wr_data  (sram_wr_data),
        .ext_addr (ext_addr),
        .ext_en   (ext_en),
        .ext_data (ext_data),
        .song_len (sram_song_len),
        .play     (song_play),
        .stop     (song_stop | rec_active),
        .pause    (song_pause),
        .pos      (song_pos),
        .playing  (song_playing),
        .gate     (song_gate),
        .vel_flat (song_vel)
    );

    flash_song u_flash_song (
        .clk        (clk_50m),
        .rst_n      (rst_n),
        .cs         (flash_cs),
        .sclk       (flash_sclk),
        .mosi       (flash_mosi),
        .miso       (flash_miso),
        .save_req   (fs_save_req),
        .cur_len    (fs_cur_len),
        .slot_sel   (fs_slot_sel),
        .delete_req (delete_req),
        .delete_busy(),
        .delete_done(delete_done),
        .save_busy  (fs_save_busy),
        .save_done  (save_done),
        .save_err   (save_err),
        .load_req   (load_req),
        .load_busy  (fs_load_busy),
        .load_done  (load_done),
        .load_active(fs_load_active),
        .wr_addr    (fs_wr_addr),
        .wr_data    (fs_wr_data),
        .wr_en      (fs_wr_en),
        .song_len   (fs_song_len),
        .lib_mask   (lib_mask),
        .lib_current(lib_current),
        .ext_addr   (ext_addr),
        .ext_data   (ext_data),
        .ext_en     (ext_en),
        .save_name  (fs_save_name),
        .name_req   (name_req),
        .name_slot  (name_slot),
        .name_done  (name_done),
        .name_data  (name_data),
        .name_valid (name_valid)
    );

    reg  signed [15:0] dry_sample;
    // ---- 4 个功能开关 (每个按键一个功能, 循环切换) ----

    // ---- 滑音: 记录上一个被按下键的音高 ----
    wire [23:0] tuning_bus [0:N_VOICE-1];
    reg  [23:0] last_inc;
    reg  [31:0] keys_prev;
    wire [31:0] key_press = keys & ~keys_prev;
    reg  [31:0] blink_counter;
    integer     voice_index;

    //-------------------------------------------------------------------------
    // 力度传感器: 板载 ADC128S102 通道 0 (板上 A0)
    //   接线: 3V3 --[ FSR 压感片 ]--+-- A0
    //                                +--[ 10k ]-- GND
    //   没接传感器时 A0 悬空约 1.665V -> 约 2048 -> 力度 128 (中等)
    //-------------------------------------------------------------------------
    wire [11:0] adc_data;
    wire        adc_vld;

    adc128s102 #(.CLK_HZ(50_000_000), .DIV(3)) u_adc (
        .clk      (clk_50m),
        .rst_n    (rst_n),
        .channel  (3'd0),
        .data     (adc_data),
        .data_vld (adc_vld),
        .adc_sclk (adc_sclk),
        .adc_cs_n (adc_cs_n),
        .adc_din  (adc_din),
        .adc_dout (adc_dout)
    );

    // 一阶低通, 用 20 位累加器(值 = ADC x 256), 右移 11 -> 时间常数约 25ms
    // 原来的 >>>4 只有 0.2ms, 等于没滤, 数字乱跳、力度不可重复
    reg  [19:0] adc_acc;
    wire signed [20:0] adc_dacc = $signed({1'b0, adc_data, 8'b0}) - $signed({1'b0, adc_acc});
    wire signed [20:0] adc_dstp = adc_dacc >>> 11;

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n)       adc_acc <= 20'd2048 * 20'd256;
        else if (adc_vld) adc_acc <= adc_acc + adc_dstp[19:0];
    end

    wire [11:0] adc_flt = adc_acc[19:8];

    // 打一拍，打断 ADC 累加器到力度/显示的长组合路径
    reg [11:0] adc_flt_r;
    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) adc_flt_r <= 12'd2048;
        else        adc_flt_r <= adc_flt;
    end

    //-------------------------------------------------------------------------
    // 反相修正: 实测 A0 接 0V 读到满码、接 3.3V 读到零码 -> 取反
    //   接线: 3.3V --[ FSR ]--+-- A0
    //                        +--[ 10k ]-- GND
    //   捏得越紧 -> A0 电压越高 -> 取反后力度数值越大
    //-------------------------------------------------------------------------
    wire [11:0] adc_inv = 12'd4095 - adc_flt_r;
    wire [7:0]  vel_raw = adc_inv[11:4];

    //-------------------------------------------------------------------------
    // 力度两点标定 (不用除法, 只用乘 3 + 移位, 避免时序被拉爆)
    //   把 64..192 拉伸到 64..255 (约 1.5 倍)
    //   如果你实测最大只有 178, 拉伸后能到 235
    //-------------------------------------------------------------------------
    localparam [7:0] VEL_LO = 8'd64;    // 松手时的读数
    localparam [7:0] VEL_HI = 8'd192;   // 拉伸上端

    wire [7:0]  vr_c  = (vel_raw < VEL_LO) ? VEL_LO :
                        (vel_raw > VEL_HI) ? VEL_HI : vel_raw;
    wire [15:0] vr_n  = (vr_c - VEL_LO) * 16'd3;
    wire [8:0]  vr_t  = 9'd64 + {1'b0, vr_n[15:1]};
    wire [7:0]  vel8  = (vr_t > 9'd255) ? 8'd255 : vr_t[7:0];

    // 力度值再打一拍，避免同时驱动 32 个 vel_latch、数码管和 LCD
    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) vel8_r <= 8'd128;
        else        vel8_r <= vel8;
    end

    // 实时力度：有键时跟随 FSR，用 4 级迟滞过滤 ADC 末位抖动
    reg [7:0] vel_show;
    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n)             vel_show <= 8'd0;
        else if (!(|keys))      vel_show <= 8'd0;
        else if (vel8_r > vel_show + 8'd4 ||
                 vel8_r + 8'd4 < vel_show)
            vel_show <= vel8_r;
    end


    //-------------------------------------------------------------------------
    // 录音: S3 开始/停止；停止后自动保存到曲库当前选中槽 lib_sel
    //-------------------------------------------------------------------------
    wire rec_toggle = (s3_press | bt_rec_cmd) &&
                      (rec_active || (!fs_save_busy && !fs_load_busy));
    recorder #(.CLK_HZ(50_000_000)) u_recorder (
        .clk        (clk_50m),
        .rst_n      (rst_n),
        .toggle     (rec_toggle),
        .clear      (rec_clear),
        .keys       (keys),
        .vel8       (8'd200),   // 方案A: 录音固定力度, 不记 FSR
        .live_gate  (live_gate),
        .live_vel   (live_vel),
        .wr_addr    (rec_wr_addr),
        .wr_data    (rec_wr_data),
        .wr_en      (rec_wr_en),
        .rec_len    (rec_len),
        .rec_active (rec_active),
        .rec_done   (rec_done),
        .rec_full   (rec_full)
    );

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            rec_done_d   <= 1'b0;
            rec_save_req <= 1'b0;
            rec_target   <= 4'd0;
        end else begin
            rec_save_req <= 1'b0;
            rec_done_d   <= rec_done;
            if (rec_toggle && !rec_active)
                rec_target <= bt_rec_cmd ? bt_rec_slot : lib_sel;
            if (rec_done && !rec_done_d && rec_len != 12'd0) rec_save_req <= 1'b1;
        end
    end

    //-------------------------------------------------------------------------
    // 32 路复音测试 (独立模块 poly_test.v)
    //   SW6 拨到 ON 进入: 每 200ms 累加一路, 6.4s 后 32 路同时响, 保持 1s 再来
    //   拨回 OFF 立即退出, 恢复正常演奏
    //-------------------------------------------------------------------------
    wire        poly_en = ~sw_n[6];
    wire [31:0] poly_gates;
    wire [255:0] poly_vels;

    poly_test #(.CLK_HZ(50_000_000), .STEP_MS(200), .HOLD_MS(1000), .VEL(90)) u_poly (
        .clk   (clk_50m),
        .rst_n (rst_n),
        .en    (poly_en),
        .gates (poly_gates),
        .vels  (poly_vels)
    );

    //-------------------------------------------------------------------------
    // v26 移植：按住时长渐强 + 显示同步
    //-------------------------------------------------------------------------
    reg [5:0] ms_div;
    reg       ms_tick;
    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            ms_div  <= 6'd0;
            ms_tick <= 1'b0;
        end else if (sample_tick) begin
            if (ms_div == 6'd48) begin
                ms_div  <= 6'd0;
                ms_tick <= 1'b1;
            end else begin
                ms_div  <= ms_div + 1'b1;
                ms_tick <= 1'b0;
            end
        end else begin
            ms_tick <= 1'b0;
        end
    end

    reg [7:0] disp_base;
    reg [7:0] disp_boost;
    reg [3:0] disp_div;
    wire any_hold = |keys;

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            disp_base  <= 8'd128;
            disp_boost <= 8'd0;
            disp_div   <= 4'd0;
        end else if (key_press != 32'd0) begin
            disp_base  <= vel8_r;
            disp_boost <= 8'd0;
            disp_div   <= 4'd0;
        end else if (!any_hold) begin
            disp_boost <= 8'd0;
            disp_div   <= 4'd0;
        end else begin
            disp_base <= vel_show;          // 按住期间实时跟随 FSR
            if (ms_tick) begin
                if (disp_div == 4'd9) begin
                    disp_div <= 4'd0;
                    if (disp_boost < 8'd48) disp_boost <= disp_boost + 1'b1;
                end else begin
                    disp_div <= disp_div + 1'b1;
                end
            end
        end
    end

    // 渐强按力度留余量：力度越大，叠加越少
    wire [8:0] disp_sum = {1'b0, disp_base} + {1'b0, disp_boost};
    wire [7:0] seg_fsr  = (|keys) ? vel_show : 8'd0;

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) disp_expr <= 8'd128;
        else if (disp_sum > 9'd255) disp_expr <= 8'd255;
        else                        disp_expr <= disp_sum[7:0];
    end

    assign voice_gates = poly_en ? poly_gates : (keys | song_gate | live_gate);

    // LCD 只需要慢速显示，门控打一拍，切断 arp_gate/keys 到 LCD 的长路径
    reg [31:0] voice_gates_lcd;
    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) voice_gates_lcd <= 32'd0;
        else        voice_gates_lcd <= voice_gates;
    end

    key_scan_8x4 #(.CLOCK_HZ(50_000_000)) scanner (
        .clk     (clk_50m),
        .rst_n   (rst_n),
        .columns (columns),
        .rows    (rows),
        .pressed (keys)
    );

    control_keys controls (
        .clk        (clk_50m),
        .reset_n    (rst_n),
        .buttons_n  (sw_n),
        .press_pulse(button_press)
    );

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            timbre        <= 2'd1;   // 1=piano, 2=guzheng, 3=xiao
            blink_counter <= 32'd0;
        end else begin
            blink_counter <= blink_counter + 1'b1;
            if (pc_timbre_set)
                timbre <= (pc_timbre == 2'd0) ? 2'd1 : pc_timbre;
            else if (button_press[0])
                timbre <= (timbre == 2'd3 || timbre == 2'd0) ? 2'd1 : timbre + 1'b1; // 1 -> 2 -> 3 -> 1
        end
    end

    //-------------------------------------------------------------------------
    // 16 个发声单元
    //-------------------------------------------------------------------------
    //-------------------------------------------------------------------------
    // 外接 4 键模块: 颤音 / 滑音 / 合唱 / 延迟
    //-------------------------------------------------------------------------
    // S1/S2 只要"按下脉冲"(点一下切换); S3/S4 要"按住电平"(按下生效, 松开恢复)
    wire [3:0] fbtn_level;
    wire [3:0] fbtn_press;

    genvar gi;
    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin : g_fbtn
            btn_debounce #(.CLOCK_HZ(50_000_000), .MS(15)) u_btn (
                .clk   (clk_50m),
                .rst_n (rst_n),
                .btn_n (func_btn_n[gi]),
                .level (fbtn_level[gi]),
                .press (fbtn_press[gi])
            );
        end
    endgenerate

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            vib_sel   <= 2'd0;
            glide_sel <= 2'd0;
        end else begin
            if (pc_vib_set)
                vib_sel <= pc_vib;
            else if (fbtn_press[0])
                vib_sel <= (vib_sel == 2'd2) ? 2'd0 : vib_sel + 1'b1;
            if (pc_glide_set)
                glide_sel <= pc_glide;
            else if (fbtn_press[1])
                glide_sel <= (glide_sel == 2'd2) ? 2'd0 : glide_sel + 1'b1;
        end
    end

    // S3 合唱 / S4 延迟: 按住生效；PC 可锁存开启
    // 合唱/延迟: 点按切换 (PC 下发优先, 实体键点按翻转)
    reg chorus_on_r, delay_on_r;
    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            chorus_on_r <= 1'b0;
            delay_on_r  <= 1'b0;
        end else begin
            if (pc_chorus_set)       chorus_on_r <= pc_chorus;
            else if (fbtn_press[2])  chorus_on_r <= ~chorus_on_r;
            if (pc_delay_set)        delay_on_r  <= pc_delay;
            else if (fbtn_press[3])  delay_on_r  <= ~delay_on_r;
        end
    end
    assign chorus_on = chorus_on_r;
    assign delay_on  = delay_on_r;

    //-------------------------------------------------------------------------
    // 滑音起点: 上一个被按下键的音高
    //-------------------------------------------------------------------------
    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) keys_prev <= 32'd0;
        else        keys_prev <= keys;
    end

    reg [23:0] press_inc;
    reg [23:0] glide_start;      // 上一个被按下键的音高（滑音起点）
    integer kk;
    always @(*) begin
        press_inc = last_inc;
        for (kk = 0; kk < N_VOICE; kk = kk + 1)
            if (key_press[kk]) press_inc = tuning_bus[kk];
    end

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            last_inc   <= 24'd0;
            glide_start <= 24'd0;
        end else if (key_press != 32'd0) begin
            glide_start <= last_inc;   // 先保存旧值，作为新音的滑音起点
            last_inc    <= press_inc;  // 再更新为最新按下的音
        end
    end

    //-------------------------------------------------------------------------
    // FSR 压力 -> 弯音 (0 ~ +2 半音, 只向上), 与上位机 PC 弯音叠加
    //-------------------------------------------------------------------------
    wire [7:0] bend_span = (vel8_r > 8'd75) ? (vel8_r - 8'd75) : 8'd0;
    wire [8:0] bend_sc   = {1'b0, bend_span} + {1'b0, bend_span[7:1]};   // x1.5
    wire [7:0] bend_raw  = (bend_sc > 9'd127) ? 8'd127 : bend_sc[7:0];

    reg [7:0] bend_q;
    reg [2:0] bend_div;
    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            bend_q   <= 8'd0;
            bend_div <= 3'd0;
        end else if (sample_tick) begin
            bend_div <= bend_div + 1'b1;
            if (bend_div == 3'd3) begin
                if      (bend_q < bend_raw) bend_q <= bend_q + 1'b1;
                else if (bend_q > bend_raw) bend_q <= bend_q - 1'b1;
            end
        end
    end

    wire [8:0] bend_disp = {1'b0, bend_q};

    // 弯音改成"加法偏移"(和上位机 pitch_bend 同一条通路), 省掉 32:1 乘法器
    //   bend_q 0..127 -> 偏移 0..11176  (约 C4 的 12%, 即 +2 半音)
    wire [23:0] fsr_bend = {16'd0, bend_q} * 24'd88;

    // 屏幕真实电平: 直接取混音输出的幅度 (就是实际听到的音量)
    //   |src_mix| 限幅到 0..255
    wire signed [16:0] lv_abs = src_mix[15] ? (-{src_mix[15], src_mix}) : {src_mix[15], src_mix};
    wire [7:0] lv_disp = (lv_abs[16:5] > 13'd255) ? 8'd255 : lv_abs[12:5];

    genvar column, row;
    generate
        for (column = 0; column < 4; column = column + 1) begin : g_col
            for (row = 0; row < 8; row = row + 1) begin : g_row
                localparam integer NOTE = column * 8 + row;
                wire [23:0] tuning;
                reg [7:0] vel_latch;
                // 曲谱音符的力度要"锁存"：note-off 后 gate 拉低，但释放段
                // 仍要用按下时的力度，否则会突然掉到键盘的 48，产生音量跳变。
                reg [7:0] song_expr;
                reg       song_active;
                reg       song_gate_d;

                // 力度: 按下瞬间锁存当前压感值
                always @(posedge clk_50m or negedge rst_n) begin
                    if (!rst_n)               vel_latch <= 8'd128;
                    else if (key_press[NOTE]) vel_latch <= vel8_r;
                end

                // v26 移植：按住时长 -> 音量递增，每 10ms +1，最多 +48
                reg [3:0] hold_div;
                reg [7:0] hold_boost;
                reg [7:0] expr_r;
                always @(posedge clk_50m or negedge rst_n) begin
                    if (!rst_n) begin
                        hold_div   <= 4'd0;
                        hold_boost <= 8'd0;
                    end else if (!keys[NOTE]) begin
                        hold_div   <= 4'd0;
                        hold_boost <= 8'd0;
                    end else if (ms_tick) begin
                        if (hold_div == 4'd9) begin
                            hold_div <= 4'd0;
                            if (hold_boost < 8'd48) hold_boost <= hold_boost + 1'b1;
                        end else begin
                            hold_div <= hold_div + 1'b1;
                        end
                    end
                end

                wire [7:0] base_now = keys[NOTE] ? vel_show : vel_latch;
                wire [8:0] expr_sum = {1'b0, base_now} + {1'b0, hold_boost};
                always @(posedge clk_50m or negedge rst_n) begin
                    if (!rst_n) expr_r <= 8'd128;
                    else if (expr_sum > 9'd255) expr_r <= 8'd255;
                    else                        expr_r <= expr_sum[7:0];
                end

                always @(posedge clk_50m or negedge rst_n) begin
                    if (!rst_n) begin
                        song_expr    <= 8'd0;
                        song_active  <= 1'b0;
                        song_gate_d  <= 1'b0;
                    end else begin
                        song_gate_d <= song_gate[NOTE];
                        if (song_gate[NOTE] && !song_gate_d) begin
                            song_expr   <= song_vel[NOTE*8 +: 8];
                            song_active <= 1'b1;
                        end
                        // 一旦这个键被现场按下，交回键盘的力度控制
                        if (key_press[NOTE])
                            song_active <= 1'b0;
                    end
                end

                // 音量 = 按住时长 (60% -> 100%, 约 370ms 到满)
                reg [9:0] hold_ms;
                reg [7:0] vol_expr;
                always @(posedge clk_50m or negedge rst_n) begin
                    if (!rst_n)                                hold_ms <= 10'd0;
                    else if (!keys[NOTE])                      hold_ms <= 10'd0;
                    else if (sample_tick && hold_ms < 10'd18000) hold_ms <= hold_ms + 1'b1;
                end
                wire [10:0] vol_sum = 11'd153 + {1'b0, hold_ms[9:2]} + {5'd0, hold_ms[9:5]};
                always @(posedge clk_50m or negedge rst_n) begin
                    if (!rst_n)                 vol_expr <= 8'd153;
                    else if (vol_sum > 11'd255) vol_expr <= 8'd255;
                    else                        vol_expr <= vol_sum[7:0];
                end

                assign voice_expression[NOTE] =
                    live_gate[NOTE] ? live_vel[NOTE*8 +: 8] :
                    song_active    ? song_expr :
                    poly_en        ? poly_vels[NOTE*8 +: 8] : vol_expr;   // 测试模式用固定力度防削顶

                note_tuning frequency (
                    .note  (NOTE[4:0]),
                    .tuning(tuning)
                );
                assign tuning_bus[NOTE] = tuning;
                synth_voice #(.FS(48828)) oscillator (
                    .clk        (clk_50m),
                    .reset_n    (rst_n),
                    .sample_tick(sample_tick),
                    .gate       (voice_gates[NOTE]),
                    .tuning     (tuning),
                    .pitch_bend (pitch_bend + {{8{1'b0}}, fsr_bend}),
                    .glide_from (glide_start),
                    .legato     (|keys_prev),
                    .vib_sel    (vib_sel),
                    .glide_sel  (glide_sel),
                    .timbre     (timbre),
                    .expression (voice_expression[NOTE]),
                    .adsr_att   (poly_en ? 16'd4000 : adsr_att_r),
                    .adsr_dec   (poly_en ? 16'd0    : adsr_dec_r),
                    .adsr_sus   (poly_en ? 16'hFFFF : adsr_sus_r),
                    .adsr_rel   (poly_en ? 16'd400  : adsr_rel_r),
                    .level      (voice_level[NOTE*8 +: 8]),
                    .audio      (voice_samples[NOTE]),
                    .active     (active_voices[NOTE])
                );
            end
        end
    endgenerate

    //-------------------------------------------------------------------------
    // 32 路求和: 改成树形流水 (原来是一条 32 级串行加法链, 23ns, 直接把 Fmax 拉到 50MHz)
    //   第1级: 8 个 4 路和 -> 打一拍
    //   第2级: 4 个 2 路和 -> 打一拍
    //   第3级: 2 个 2 路和 -> 打一拍
    //   第4级: 1 个 2 路和 -> 打一拍
    //   总延迟 4 个时钟 = 80ns, 对 48.8kHz 的采样周期(20.5us)完全无影响
    //-------------------------------------------------------------------------
    wire signed [21:0] v_x [0:31];
    genvar gx;
    generate
        for (gx = 0; gx < 32; gx = gx + 1) begin : g_ext
            assign v_x[gx] = {{6{voice_samples[gx][15]}}, voice_samples[gx]};

        end
    endgenerate

    // Track newest voice onset, highest note wins simultaneous chord onsets.
    // Keep the selected voice after gate-off so its complete release is visible.
    reg [31:0] env_gates_d;
    reg [4:0] env_note_idx;
    wire [31:0] env_rise = voice_gates & ~env_gates_d;
    wire env_note_valid = voice_gates[env_note_idx] || (env_level != 8'd0);
    integer env_i;
    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin env_gates_d<=0; env_note_idx<=0; env_level<=0; end
        else begin
            env_gates_d <= voice_gates;
            for (env_i=0; env_i<32; env_i=env_i+1)
                if (env_rise[env_i]) env_note_idx <= env_i[4:0];
            env_level <= voice_level[env_note_idx*8 +: 8];
        end
    end

    reg signed [21:0] s_l1_0, s_l1_1, s_l1_2, s_l1_3, s_l1_4, s_l1_5, s_l1_6, s_l1_7;
    reg signed [21:0] s_l2_0, s_l2_1, s_l2_2, s_l2_3;
    reg signed [21:0] s_l3_0, s_l3_1;
    reg signed [21:0] voice_sum_r;

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            s_l1_0<=0; s_l1_1<=0; s_l1_2<=0; s_l1_3<=0;
            s_l1_4<=0; s_l1_5<=0; s_l1_6<=0; s_l1_7<=0;
            s_l2_0<=0; s_l2_1<=0; s_l2_2<=0; s_l2_3<=0;
            s_l3_0<=0; s_l3_1<=0;
            voice_sum_r <= 0;
        end else begin
            s_l1_0 <= v_x[ 0] + v_x[ 1] + v_x[ 2] + v_x[ 3];
            s_l1_1 <= v_x[ 4] + v_x[ 5] + v_x[ 6] + v_x[ 7];
            s_l1_2 <= v_x[ 8] + v_x[ 9] + v_x[10] + v_x[11];
            s_l1_3 <= v_x[12] + v_x[13] + v_x[14] + v_x[15];
            s_l1_4 <= v_x[16] + v_x[17] + v_x[18] + v_x[19];
            s_l1_5 <= v_x[20] + v_x[21] + v_x[22] + v_x[23];
            s_l1_6 <= v_x[24] + v_x[25] + v_x[26] + v_x[27];
            s_l1_7 <= v_x[28] + v_x[29] + v_x[30] + v_x[31];

            s_l2_0 <= s_l1_0 + s_l1_1;
            s_l2_1 <= s_l1_2 + s_l1_3;
            s_l2_2 <= s_l1_4 + s_l1_5;
            s_l2_3 <= s_l1_6 + s_l1_7;

            s_l3_0 <= s_l2_0 + s_l2_1;
            s_l3_1 <= s_l2_2 + s_l2_3;

            voice_sum_r <= s_l3_0 + s_l3_1;
        end
    end

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) dry_sample <= 16'sd0;
        else if ((voice_sum_r >>> 4) > 22'sd32767)       dry_sample <= 16'sd32767;
        else if ((voice_sum_r >>> 4) < -22'sd32768)      dry_sample <= -16'sd32768;
        else                                             dry_sample <= voice_sum_r[19:4];
    end

    audio_effects effects (
        .clk        (clk_50m),
        .reset_n    (rst_n),
        .sample_tick(sample_tick),
        .delay_on   (delay_on),
        .chorus_on  (chorus_on),
        .dry_sample (dry_sample),
        .wet_sample (processed_sample)
    );

    //-------------------------------------------------------------------------
    // 上电自动测试音: 前 3 秒输出 440Hz 满幅方波, 不用碰拨码就能听到
    //-------------------------------------------------------------------------
    reg [27:0] boot_cnt;
    reg [16:0] sq_cnt;
    reg        sq_bit;

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            boot_cnt <= 28'd0;
            sq_cnt   <= 17'd0;
            sq_bit   <= 1'b0;
        end else begin
            if (boot_cnt < 28'd150_000_000) boot_cnt <= boot_cnt + 1'b1;

            if (sq_cnt >= 17'd56818) begin          // 50MHz/440Hz/2
                sq_cnt <= 17'd0;
                sq_bit <= ~sq_bit;
            end else begin
                sq_cnt <= sq_cnt + 1'b1;
            end
        end
    end

    wire boot_tone = (boot_cnt < 28'd150_000_000);
    wire signed [15:0] sq_sample = sq_bit ? 16'sd28000 : -16'sd28000;

    //-------------------------------------------------------------------------
    // 总音量: EC11 旋钮 0~63 档, 作用在混音之后 (含上电自检音)
    //   vol=42 -> 1.00x (上电默认), vol=63 -> 1.50x, vol=0 -> 静音
    //   与逐声部力度相乘, 互不覆盖
    //-------------------------------------------------------------------------

    rotary_vol #(.CLOCK_HZ(50_000_000)) u_vol (
        .clk     (clk_50m),
        .rst_n   (rst_n),
        .rot_a   (rot_a),
        .rot_b   (rot_b),
        .rot_sw  (rot_sw),
        .lock_vol(1'b0),
        .pc_set  (pc_vol_set),
        .pc_vol  (pc_vol),
        .vol     (vol),
        .gain_q8 (gain_q8),
        .step_o  (rot_step),
        .dir_o   (rot_dir)
    );

    wire signed [15:0] src_mix = boot_tone ? sq_sample : processed_sample;
    wire signed [26:0] vol_mul = src_mix * $signed({1'b0, gain_q8});
    wire signed [26:0] vol_sh  = vol_mul >>> 8;      // Q8 还原

    // 打一拍再输出, 打断 "乘法->移位->限幅" 的长组合路径
    reg signed [15:0] vol_out_r;
    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) vol_out_r <= 16'sd0;
        else        vol_out_r <= (vol_sh > 27'sd32767)  ? 16'sd32767 :
                                 (vol_sh < -27'sd32768) ? -16'sd32768 : vol_sh[15:0];
    end

    assign dac_l = vol_out_r;
    assign dac_r = vol_out_r;

    // 送 LCD 的是音量之后的信号: 示波器/频谱/音量条都跟音量实时变化
    reg signed [15:0] lcd_audio;
    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) lcd_audio <= 16'sd0;
        else        lcd_audio <= vol_out_r;   // 自检音不上屏
    end

    //-------------------------------------------------------------------------
    // 诊断
    //-------------------------------------------------------------------------
    reg        dd_d0;
    reg [15:0] dd_cnt;
    reg [19:0] dd_win;
    reg        dacdat_act;

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            dd_d0      <= 1'b0;
            dd_cnt     <= 16'd0;
            dd_win     <= 20'd0;
            dacdat_act <= 1'b0;
        end else begin
            dd_d0 <= codec_dacdat;
            if (dd_d0 != codec_dacdat) dd_cnt <= dd_cnt + 1'b1;
            if (dd_win == 20'hFFFFF) begin
                dd_win <= 20'd0;
                if (dd_cnt > 16'd100) dacdat_act <= 1'b1;
                dd_cnt <= 16'd0;
            end else begin
                dd_win <= dd_win + 1'b1;
            end
        end
    end

    wire audio_nz = (dry_sample != 16'sd0) | boot_tone;

    // 帧节拍计数器 (给 D4 用)
    reg [15:0] sample_tick_r;
    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n)           sample_tick_r <= 16'd0;
        else if (sample_tick) sample_tick_r <= sample_tick_r + 1'b1;
    end

    //-------------------------------------------------------------------------
    // 指示灯 (6 盏): 前 4 盏对应 4 个功能, 后 2 盏是系统指示
    //   三联灯:  灭 = 关,  慢闪(约1.5Hz) = 低档,  常亮 = 高档
    //-------------------------------------------------------------------------
    wire blink_slow = blink_counter[23];   // 约 1.5 Hz

    assign leds[0] = (vib_sel   == 2'd0) ? 1'b0 :          // D2 颤音
                     (vib_sel   == 2'd1) ? blink_slow : 1'b1;
    assign leds[1] = (glide_sel == 2'd0) ? 1'b0 :          // D3 滑音
                     (glide_sel == 2'd1) ? blink_slow : 1'b1;
    assign leds[2] = chorus_on;                            // D4 合唱(点按常亮)
    assign leds[3] = delay_on;                             // D5 延迟(点按常亮)
    assign leds[4] = audio_nz | bt_act;                   // D6 有音频 / 蓝牙有数据
    assign leds[5] = bt_link ? 1'b1 : blink_counter[25];  // D7 蓝牙已连常亮，否则心跳

    //-------------------------------------------------------------------------
    // 74HC595 数码管: 左侧 4 位显示 "t<音色> <音量>"
    //   实测: 段码低有效, 位选高有效, 先段后位
    //-------------------------------------------------------------------------
    seg7_595 u_seg7 (
        .clk      (clk_50m),
        .rst_n    (rst_n),
        .timbre   (timbre),
        .vol      (vol),
        .seg_dio  (seg7_dio),
        .seg_sclk (seg7_sclk),
        .seg_rclk (seg7_rclk),
        .vel_disp (bend_disp),
        .flash_id (24'd0),
        .flash_pass (1'b0),
        .flash_fail (1'b0)
    );


    //-------------------------------------------------------------------------
    // WS2812B 灯带: 按下第 N 个键 -> 第 N 颗灯亮
    //-------------------------------------------------------------------------
    //-------------------------------------------------------------------------
    // WS2812B 灯带: 物理键用当前力度，回放用每个音符的 song_vel
    //-------------------------------------------------------------------------
    wire [255:0] led_vels;
    genvar li;
    generate
        for (li = 0; li < 32; li = li + 1) begin : g_led_vel
            wire [7:0] sv = song_vel[li*8 +: 8];
            wire [7:0] lv = live_vel[li*8 +: 8];
            assign led_vels[li*8 +: 8] = poly_en ? poly_vels[li*8 +: 8] :
                                         live_gate[li] ? lv :
                                         keys[li] ? disp_expr :
                                        (song_gate[li] ? sv : 8'd0);
        end
    endgenerate

    ws2812_piano #(.N_LED(32), .CLK_HZ(50_000_000)) u_ws2812 (
        .clk         (clk_50m),
        .rst_n       (rst_n),
        .keys        (keys | song_gate | live_gate | (poly_en ? poly_gates : 32'd0)),
        .vels        (led_vels),
        .black_mask  (32'h2A52A52A),   // F4..C7: 13 个黑键
        .color_white (24'h00_40_00),   // 白键红色 {G,R,B}
        .color_black (24'h00_00_40),   // 黑键蓝色
        .dout        (ws2812_din)
    );

    //-------------------------------------------------------------------------
    // LCD 480x320 live dashboard + note activity page
    //-------------------------------------------------------------------------
    lcd_dashboard u_boot (
        .clk50    (clk_50m),
        .rst_n    (rst_n),
        .lcd_cs   (lcd_cs),
        .lcd_rst  (lcd_rst),
        .lcd_dc   (lcd_dc),
        .lcd_mosi (lcd_mosi),
        .lcd_sck  (lcd_sck),
        .boot_done(),
        .timbre_in   (timbre),
        .bt_link     (bt_link),
        .rec_active  (rec_active),
        .song_playing(song_playing),
        .s1_tick     (s1_press),
        .vol_in      (vol),
        .gates_in    (voice_gates),
        .levels_in   (voice_level),
        .note_in     (env_note_idx),
        .note_valid_in(env_note_valid),
        .vib_sel_in  (vib_sel),
        .glide_sel_in(glide_sel),
        .chorus_on_in(chorus_on),
        .delay_on_in (delay_on),
        .env_level_in(env_level)
    );
endmodule

