//=============================================================================
// synth_voice.v — 单个发声单元 (DDS + ADSR + 谐波音色 + 颤音 + 滑音)
//
//   v11 音色升级 + 资源共享:
//     1) 每声部只放 1 个 1024x12 同步正弦 ROM (BSRAM), 不再并行放 5 个 LUT
//     2) 每个采样周期用 7 拍依次读: 基频 / 2次 / 3次 / 4次 / FM 相位
//     3) 谐波仍然用移位相加, 不增加乘法器
//     4) 修正输出缩放 (>>>5), 修正 FM 相位偏移的位宽
//     5) Attack 噪声加在缩放之后, 不会被移位吃掉
//
//   资源: 32 声部 x 1 BSRAM = 32 块 BSRAM (每块 1024x12)
//   时序: 7 拍 @50MHz = 140ns, 远小于 20.5us 的采样周期
//=============================================================================
`timescale 1ns/1ps

module synth_voice #(
    parameter integer FS = 48828
)(
    input  wire        clk,
    input  wire        reset_n,
    input  wire        sample_tick,
    input  wire        gate,

    input  wire [23:0] tuning,       // 目标相位增量 (音高)
    input  wire [23:0] glide_from,   // 滑音起点
    input  wire        legato,
    input  wire [1:0]  vib_sel,      // 颤音档: 0=关 1=浅 2=深
    input  wire [1:0]  glide_sel,    // 滑音档: 0=关 1=快 2=慢

    input  wire [1:0]  timbre,
    input  wire signed [31:0] pitch_bend,   // PC 弯音 (上位机下发, 绝对偏移)
    // ADSR 参数由顶层按音色算好传进来 (避免每个声部各做一套选择器,
    // 那一版把 timbre 扇出到 32 个声部, 长走线 10ns, Fmax 压到 50.1MHz)
    input  wire [15:0] adsr_att,
    input  wire [15:0] adsr_dec,
    input  wire [15:0] adsr_rel,
    input  wire [15:0] adsr_sus,
    input  wire [7:0]  expression,

    output wire [7:0]  level,        // 当前包络电平 0..255 (给屏幕显示真实音量)
    output reg  signed [15:0] audio,
    output wire        active
);

    //---------------------------------------------------------------------
    // 音色锁存: 只在起音那一刻采样一次
    //   ① 切断 timbre 到 32 个声部的长扇出 (实测占 4~8ns, 把 Fmax 压到 50.0)
    //   ② 更符合真实乐器: 一个音的音色在起音时就定了, 之后换音色不影响它
    //---------------------------------------------------------------------
    reg [1:0] timbre_v;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n)                timbre_v <= 2'd1;
        else if (gate & ~gate_clk_d)     timbre_v <= (timbre == 2'd0) ? 2'd1 : timbre;
    end

    // 起音后 150ms 内算"亮音期" (古筝的高次谐波在起音时最丰富)
    reg [15:0] age_cnt;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n)              age_cnt <= 16'd0;
        else if (gate & ~gate_clk_d)   age_cnt <= 16'd0;
        else if (sample_tick && age_cnt < 16'd20000) age_cnt <= age_cnt + 1'b1;
    end
    wire bright_early = (age_cnt < 16'd7200);

    //-------------------------------------------------------------------------
    // ADSR 参数
    //-------------------------------------------------------------------------
    localparam [15:0] FULL  = 16'hFFFF;
    localparam [15:0] SUS_X = 16'd55705;   // 箫: 0.85 保持
    localparam [15:0] SUS_Z = 16'd0;       // 钢琴/古筝: 不保持

    // 钢琴 0: A 2ms   D 300ms S 0    R 120ms  (击弦, 不保持)
    // 古筝 1: A 1ms   D 450ms S 0    R 150ms  (拨弦, 余韵更长)
    // 箫   2: A 120ms D 200ms S 0.85 R 200ms  (慢起音, 持续)
    // 注意: FULL/D 是整数除法, D 超过 1342ms 步进会变成 0, 包络永不衰减!
    //   钢琴: D 设 1200ms -> 步进 1 -> 实际衰减 1342ms (长, 能听出力度和颤音)
    //   古筝: D 设 350ms  -> 步进 3 -> 实际衰减 447ms  (短促, 拨弦感)
    //   箫  : D 设 200ms  -> 步进 6 -> 实际衰减 224ms
    localparam integer NA0 = (FS/1000)*2,   ND0 = (FS/1000)*1200, NR0 = (FS/1000)*300;
    localparam integer NA1 = (FS/1000)*1,   ND1 = (FS/1000)*1200, NR1 = (FS/1000)*300;
    localparam integer NA2 = (FS/1000)*120, ND2 = (FS/1000)*200,  NR2 = (FS/1000)*200;

    localparam [15:0] A0 = FULL           / NA0;
    localparam [15:0] A1 = FULL           / NA1;
    localparam [15:0] A2 = FULL           / NA2;
    localparam [15:0] D0 = FULL           / ND0;
    localparam [15:0] D1 = FULL           / ND1;
    localparam [15:0] D2 = (FULL - SUS_X) / ND2;
    localparam [15:0] R0 = FULL           / NR0;
    localparam [15:0] R1 = FULL           / NR1;
    localparam [15:0] R2 = FULL           / NR2;



    localparam [2:0] S_IDLE = 3'd0,
                     S_ATT  = 3'd1,
                     S_DEC  = 3'd2,
                     S_SUS  = 3'd3,
                     S_REL  = 3'd4;

    localparam [23:0] LFO_INC = 24'd1890;         // 5.5 Hz @ 48.83 kHz

    //-------------------------------------------------------------------------
    // 寄存器
    //-------------------------------------------------------------------------
    reg  [2:0]  st;
    reg  [15:0] lvl;
    assign level = lvl[15:8];   // 包络电平, 用于屏幕显示
    reg         gate_d;
    // Capture even a clock-wide gate transition between audio sample ticks.
    reg gate_clk_d, onset_pending;
    wire onset = onset_pending | (gate & ~gate_clk_d);
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin gate_clk_d<=0; onset_pending<=0; end
        else begin
            gate_clk_d <= gate;
            if (sample_tick) onset_pending <= 0;
            else if (gate & ~gate_clk_d) onset_pending <= 1;
        end
    end

    reg  [23:0] cur_inc;
    reg  [23:0] lfo_acc;
    reg  [23:0] phase;
    reg  [23:0] phase_s;         // 本采样周期的相位快照 (给波表读用)
    reg  [15:0] noise_lfsr;

    // 单 ROM 分时读序列
    reg  [2:0]  step;            // 0=idle, 1..7
    reg  [9:0]  lut_addr;
    wire signed [11:0] sine_data;
    reg  signed [11:0] s1, s2, s3, s4, s_fm;

    //-------------------------------------------------------------------------
    // 谐波相位
    //-------------------------------------------------------------------------
    wire [23:0] phase3_s   = phase_s + (phase_s << 1);
    wire signed [23:0] fm_offset = {{12{s2[11]}}, s2} <<< 10;
    wire [23:0] fm_phase_s = phase_s + fm_offset;

    //-------------------------------------------------------------------------
    // 谐波相加 (14 位, 防中间溢出)
    //-------------------------------------------------------------------------
    wire signed [13:0] e1 = {{2{s1[11]}}, s1};
    wire signed [13:0] e2 = {{2{s2[11]}}, s2};
    wire signed [13:0] e3 = {{2{s3[11]}}, s3};
    wire signed [13:0] e4 = {{2{s4[11]}}, s4};
    wire signed [13:0] e_fm = {{2{s_fm[11]}}, s_fm};

    reg signed [13:0] osc_mix;
    always @(*) begin
        case (timbre_v)
            2'd1: // 钢琴: 温暖饱满, 高次谐波少 (基频突出)
                osc_mix = e1 + (e2 >>> 1) + (e3 >>> 3);
            2'd2: // 古筝: 按实测录音配比
                //   h1 0.25 / h2 0.56 / h3 1.00 / h4 0.56  (h3 最强, 基频最弱)
                //   起音 150ms 内 h4 更足, 之后回落 -> "铮" 转 "嗡"
                osc_mix = (e1 >>> 2) + (e2 >>> 1) + (e2 >>> 4) + e3
                        + (bright_early ? ((e4 >>> 1) + (e4 >>> 4))
                                        :  (e4 >>> 2));
            2'd3: // 箫: 主要基频 + 一点二次 (接近正弦, 纯净)
                osc_mix = e1 + (e2 >>> 2);
            default: osc_mix = e1 + (e2 >>> 1) + (e3 >>> 3);
        endcase
    end

    //-------------------------------------------------------------------------
    // 起音噪声: 加在缩放之后, 幅度 ±8
    //-------------------------------------------------------------------------
    wire signed [8:0]  attack_noise    = $signed({1'b0, noise_lfsr[7:0]}) - 9'sd128;
    wire signed [11:0] attack_noise_12 = {{3{attack_noise[8]}}, attack_noise};
    // 噪声: 钢琴只在起音加短促爆点; 箫全程加轻微"气声"
    wire noise_en = (timbre_v == 2'd1) ? (st == S_ATT) :
                    (timbre_v == 2'd3) ? (st != S_IDLE) : 1'b0;
    wire signed [11:0] noise_gain = (timbre_v == 2'd3)
                                  ? (attack_noise_12 >>> 6) : (attack_noise_12 >>> 4);
    wire signed [11:0] noise_term = noise_en ? noise_gain : 12'sd0;

    //-------------------------------------------------------------------------
    // 幅度: 3867 -> 120, 和旧版 ±128 接近; 最高声部 120*4079/32 = 15296
    //-------------------------------------------------------------------------
    wire signed [13:0] osc_sum    = (osc_mix >>> 5) + noise_term;
    wire signed [11:0] oscillator = osc_sum[11:0];

    wire [19:0]        gain_prod  = lvl[15:4] * expression;
    wire [11:0]        gain12     = gain_prod[19:8];
    wire signed [24:0] scaled     = oscillator * $signed({1'b0, gain12});

    //-------------------------------------------------------------------------
    // 波表地址分时选择
    //-------------------------------------------------------------------------
    always @(*) begin
        case (step)
            3'd1: lut_addr = phase_s[23:14];          // 基频
            3'd2: lut_addr = phase_s[22:13];          // 2 次
            3'd3: lut_addr = phase3_s[23:14];         // 3 次
            3'd4: lut_addr = phase_s[21:12];          // 4 次
            3'd5: lut_addr = fm_phase_s[23:14];       // FM 载波相位
            default: lut_addr = 10'd0;
        endcase
    end

    // 每声部一个同步 ROM, 1 拍读延迟
    sine_lut u_sine_lut (
        .clk  (clk),
        .addr (lut_addr),
        .data (sine_data)
    );

    //-------------------------------------------------------------------------
    // 颤音
    //-------------------------------------------------------------------------
    wire [14:0] lfo_tri = lfo_acc[15] ? ~lfo_acc[14:0] : lfo_acc[14:0];
    wire signed [17:0] lfo_s = $signed({3'b000, lfo_tri}) - 18'sd16384;

    // 颤音淡入: 0..3 档, 每约 84ms 升一档 -> 250ms 到满
    //   (真实演奏里颤音是"逐渐加上去"的, 一按就抖很假)
    reg [1:0]  vib_g;
    reg [11:0] vib_div;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            vib_g   <= 2'd0;
            vib_div <= 12'd0;
        end else if (!gate) begin
            vib_g   <= 2'd0;
            vib_div <= 12'd0;
        end else if (sample_tick) begin
            if (vib_div == 12'h0FF) begin   // 5.2ms/档, 共 16ms 到满 (再慢就跟不上短音)
                vib_div <= 12'd0;
                if (vib_g != 2'd3) vib_g <= vib_g + 1'b1;
            end else begin
                vib_div <= vib_div + 1'b1;
            end
        end
    end

    // ★ 深度与音高成正比
    //   原来是绝对值加减, 低音区抖得厉害、高音区只有 6 音分(听不出)。
    //   vib_oct ≈ 当前频率/65536 (低音区约 1, 高音区约 5), 乘上去后
    //   整个键盘的音分数基本一致 (约 20 / 40 音分)。
    wire [2:0] vib_oct = cur_inc[18:16];

    wire signed [17:0] vib_raw = (vib_sel == 2'd1) ? (lfo_s >>> 3) :   // 浅 ≈ 40 音分
                                 (vib_sel == 2'd2) ? (lfo_s >>> 2) :   // 深 ≈ 80 音分
                                                    18'sd0;

    // 用移位相加代替乘法器 (乘数是 3 位 0..7, 只需 2 个加法器)
    // 否则 32 个声部要吃 16 个 DSP, Fmax 掉到 44MHz
    wire signed [21:0] vib_base = {{4{vib_raw[17]}}, vib_raw};
    wire signed [21:0] vib_mul  = (vib_oct[0] ? vib_base : 22'sd0)
                                + (vib_oct[1] ? (vib_base <<< 1) : 22'sd0)
                                + (vib_oct[2] ? (vib_base <<< 2) : 22'sd0);

    // 淡入: 按档位右移 (4 选 1, 不用乘法器)
    wire signed [21:0] vib_sh = (vib_g == 2'd0) ? (vib_mul >>> 3) :
                                (vib_g == 2'd1) ? (vib_mul >>> 2) :
                                (vib_g == 2'd2) ? (vib_mul >>> 1) : vib_mul;

    wire [23:0] vib_mod = {{2{vib_sh[21]}}, vib_sh};

    //-------------------------------------------------------------------------
    // 滑音
    //-------------------------------------------------------------------------
    wire signed [24:0] glide_diff = $signed({1'b0, tuning}) - $signed({1'b0, cur_inc});

    // 滑音步进
    //   ★ 原来直接 diff>>>15, 当 |diff| < 32768 时步进变 0, 音高就永远停在
    //     离目标很远的地方(最多差 5 个半音) -> 听感就是"调一直在变/跑调"。
    //   ★ 修正: 至少走 1 步, 保证一定能精确到达目标; 到达即停(上面有 !=tuning 判断)
    wire signed [24:0] glide_raw = (glide_sel == 2'd1) ? (glide_diff >>> 11)
                                                       : (glide_diff >>> 14);
    reg  signed [24:0] glide_step;
    always @(*) begin
        case (glide_sel)
            2'd1:    glide_step = (glide_raw == 0) ? ((glide_diff > 0) ?  25'sd1 :
                                                      (glide_diff < 0) ? -25'sd1 : 25'sd0)
                                                  : glide_raw;
            2'd2:    glide_step = (glide_raw == 0) ? ((glide_diff > 0) ?  25'sd1 :
                                                      (glide_diff < 0) ? -25'sd1 : 25'sd0)
                                                  : glide_raw;
            default: glide_step = 25'sd0;
        endcase
    end

    //-------------------------------------------------------------------------
    // 主逻辑
    //-------------------------------------------------------------------------
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            st         <= S_IDLE;
            lvl        <= 16'd0;
            gate_d     <= 1'b0;
            cur_inc    <= 24'd0;
            lfo_acc    <= 24'd0;
            phase      <= 24'd0;
            phase_s    <= 24'd0;
            noise_lfsr <= 16'h1;
            step       <= 3'd0;
            s1         <= 12'sd0;
            s2         <= 12'sd0;
            s3         <= 12'sd0;
            s4         <= 12'sd0;
            s_fm       <= 12'sd0;
            audio      <= 16'sd0;
        end else if (sample_tick) begin
            gate_d <= gate;

            //-----------------------------------------------------------------
            // ADSR
            //-----------------------------------------------------------------
            // A new strike always restarts attack, including during release.
            if (onset && gate) begin
                lvl <= 16'd0;
                st <= S_ATT;
            end else case (st)
            S_IDLE: begin
                lvl <= 16'd0;
                if (gate) st <= S_ATT;
            end
            S_ATT: begin
                if (!gate) begin
                    st <= S_REL;
                end else if (lvl >= FULL - adsr_att) begin
                    lvl <= FULL;
                    st  <= S_DEC;
                end else begin
                    lvl <= lvl + adsr_att;
                end
            end
            S_DEC: begin
                if (!gate) begin
                    st <= S_REL;
                end else if (lvl <= adsr_sus + adsr_dec) begin
                    lvl <= adsr_sus;
                    st  <= S_SUS;
                end else begin
                    lvl <= lvl - adsr_dec;
                end
            end
            S_SUS: begin
                if (!gate) st <= S_REL;
            end
            S_REL: begin
                if (lvl <= adsr_rel) begin
                    lvl <= 16'd0;
                    st  <= S_IDLE;
                end else begin
                    lvl <= lvl - adsr_rel;
                end
            end
            default: st <= S_IDLE;
            endcase

            //-----------------------------------------------------------------
            // 滑音
            //-----------------------------------------------------------------
            if (onset && gate) begin
                cur_inc <= (legato && (glide_sel != 2'd0) && (glide_from != 24'd0))
                           ? glide_from : tuning;
            end else if (cur_inc != tuning) begin
                cur_inc <= cur_inc + glide_step[23:0];
            end

            //-----------------------------------------------------------------
            // 颤音 / 噪声
            //-----------------------------------------------------------------
            lfo_acc <= lfo_acc + LFO_INC;
            noise_lfsr <= {noise_lfsr[14:0],
                           noise_lfsr[15] ^ noise_lfsr[13] ^
                           noise_lfsr[12] ^ noise_lfsr[10]};

            //-----------------------------------------------------------------
            // 启动波表序列
            //-----------------------------------------------------------------
            if (gate || (st != S_IDLE)) begin
                phase_s <= phase;
                if (onset && gate)
                    phase <= 24'd0;                  // 起音清相位
                else
                    phase <= phase + cur_inc + vib_mod + pitch_bend[23:0];   // FSR弯音在顶层已乘进 tuning, PC弯音在这里加
                step <= 3'd1;
            end else begin
                phase_s <= phase;
                step    <= 3'd0;
                audio   <= 16'sd0;
            end
        end else begin
            //-----------------------------------------------------------------
            // 7 拍分时读: 1=发地址, 2..6=取数, 7=算输出
            //-----------------------------------------------------------------
            case (step)
                3'd1: step <= 3'd2;
                3'd2: begin s1   <= sine_data; step <= 3'd3; end
                3'd3: begin s2   <= sine_data; step <= 3'd4; end
                3'd4: begin s3   <= sine_data; step <= 3'd5; end
                3'd5: begin s4   <= sine_data; step <= 3'd6; end
                3'd6: begin s_fm <= sine_data; step <= 3'd7; end
                3'd7: begin audio <= scaled[20:5]; step <= 3'd0; end   // 等价 >>>5，显式取 16 位
                default: step <= 3'd0;
            endcase
        end
    end

    assign active = (st != S_IDLE);

endmodule
