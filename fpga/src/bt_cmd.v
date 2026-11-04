//=============================================================================
// bt_cmd.v — 蓝牙命令处理 + 曲库写入 + 回复
//
//   命令:
//     0x01 PING
//     0x20 SONG_BEGIN   载荷: count_lo, count_hi          (事件数, <=4095)
//     0x21 SONG_EVENTS  载荷: N*4 字节事件 (N<=15)
//     0x22 SONG_END     载荷: sum[31:0] (小端, 所有事件字的和)
//     0x23 PLAY
//     0x24 STOP
//     0x25 PAUSE        (第一版等同 STOP)
//     0x30 STATUS
//
//   回复统一为 0xE0，8 字节:
//     [0] last_cmd  [1] status(0=ok) [2] playing
//     [3] pos_lo    [4] pos_hi[3:0]
//     [5] len_lo    [6] len_hi[3:0]  [7] err
//
//   SONG_EVENTS 不回包（否则 1300 多帧会把串口灌满），
//   由 SONG_END 的 ACK/NAK 和 STATUS 确认。
//=============================================================================
`timescale 1ns/1ps

module bt_cmd (
    input  wire         clk,
    input  wire         rst_n,

    //---- 来自 bt_rx_frame ----
    input  wire         frame_valid,
    input  wire [7:0]   frame_cmd,
    input  wire [5:0]   frame_len,
    input  wire [511:0] frame_payload,
    output reg          frame_ack,

    //---- 曲库写口 ----
    output reg  [11:0]  song_wr_addr,
    output reg  [31:0]  song_wr_data,
    output reg          song_wr_en,
    output reg  [11:0]  song_len,

    //---- 播放控制 ----
    output reg          song_play,
    output reg          song_stop,
    output reg          song_pause,

    input  wire [11:0]  song_pos,
    input  wire         song_playing,

    //---- 串口发送 ----
    output reg  [7:0]   tx_data,
    output reg          tx_start,
    input  wire         tx_busy,

    //---- 指示 ----
    input  wire         bt_state,
    output reg          led_link,
    output reg          led_act,

    //---- Flash 保存握手 ----
    output reg          save_req,
    input  wire         save_done,
    input  wire         save_err,

    //---- 多曲库槽位 ----
    output reg  [3:0]   slot_sel,
    output reg          load_req,
    input  wire         load_done,
    output reg          delete_req,
    input  wire         delete_done,

    //---- Flash 里已加载的曲目长度 ----
    input  wire [11:0]  ext_len,
    //---- 曲库槽位状态 ----
    input  wire [15:0]  lib_mask,
    input  wire [3:0]   lib_current,

    //---- 脱机播放按键 (板载 S2) ----
    input  wire         play_key,
    //---- 曲库页 S2: 加载选中槽并播放 ----
    input  wire         lib_play,
    input  wire [3:0]   lib_slot,

    //---- 曲名存储/读取 ----
    output reg  [127:0] save_name,
    output reg          name_req,
    output reg  [3:0]   name_slot,
    input  wire         name_done,
    input  wire [127:0] name_data,
    input  wire         name_valid,

    //---- 录音清空 (新曲/加载时) ----
    output reg          rec_clear,
    //---- 录音状态 ----
    input  wire         rec_active,
    input  wire [11:0]  rec_len,
    input  wire         rec_full,
    //---- 实体琴实时状态（遥测）----
    input  wire [31:0]  keys,
    input  wire [7:0]   vel8,
    input  wire [4:0]   vol,
    input  wire [1:0]   timbre,
    input  wire [1:0]   vib_sel,
    input  wire [1:0]   glide_sel,
    input  wire         chorus_on,
    input  wire         delay_on,
    //---- 真实波形采样 ----
    input  wire         sample_tick,
    input  wire signed [15:0] scope_audio,
    //---- 小程序录音控制 ----
    output reg          rec_cmd,
    output reg  [3:0]   rec_slot,
    //---- PC 实时演奏 ----
    output reg  [31:0]  live_gate,
    output reg  [255:0] live_vel,
    output reg signed [31:0] pitch_bend,
    //---- PC 参数控制 ----
    output reg  [4:0]   pc_vol,
    output reg          pc_vol_set,
    output reg  [1:0]   pc_timbre,
    output reg          pc_timbre_set,
    output reg  [1:0]   pc_vib,
    output reg          pc_vib_set,
    output reg  [1:0]   pc_glide,
    output reg          pc_glide_set,
    output reg          pc_chorus,
    output reg          pc_chorus_set,
    output reg          pc_delay,
    output reg          pc_delay_set,
    output reg  [15:0]  adsr_att,
    output reg  [15:0]  adsr_dec,
    output reg  [15:0]  adsr_sus,
    output reg  [15:0]  adsr_rel
);

    localparam [3:0] C_IDLE   = 4'd0,
                     C_EVENTS = 4'd1,
                     C_REPLY  = 4'd2,
                     C_CRC    = 4'd3,
                     C_TX     = 4'd4,
                     C_TXW    = 4'd5,
                     C_TXD    = 4'd6,
                     C_GAP    = 4'd7,
                     C_SAVE   = 4'd8,
                     C_LOAD   = 4'd9,
                     C_DEL    = 4'd10,
                     C_LIB_LOAD = 4'd11,
                     C_NAME   = 4'd12,
                     C_SCOPE_FILL = 4'd13,
                     C_SCOPE_GAP  = 4'd14;
    reg [3:0]  st;
    reg [7:0]  last_cmd;
    reg [7:0]  status;
    reg [7:0]  err;
    reg        name_part;

    reg [11:0] wr_ptr;
    reg [31:0] sum;
    reg [27:0] save_wait;

    reg [5:0]  evt_n;
    reg [5:0]  evt_i;

    reg [7:0]  rbuf [0:18];
    reg [4:0]  crc_i;
    reg [4:0]  crc_lim;
    reg [15:0] crc_v;
    reg [4:0]  tx_i;
    reg [4:0]  tx_len;

    reg [20:0] act_cnt;
    integer k;

    //-------------------------------------------------------------------------
    // 真实波形采样：48.828k ÷8 = 6.103k，256 x 16bit
    //-------------------------------------------------------------------------
    reg [15:0] scope_buf [0:127];
    reg       scope_req;
    reg       scope_cap;
    reg       scope_ready;
    reg       scope_stream;
    reg       scope_single;
    reg       scope_burst;
    reg       scope_consume;
    reg [7:0] scope_wr;
    reg [2:0] scope_div;
    reg [4:0] scope_chunk;
    reg [7:0] scope_send;
    reg [15:0] scope_gap;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scope_cap   <= 1'b0;
            scope_ready <= 1'b0;
            scope_wr    <= 8'd0;
            scope_div   <= 3'd0;
        end else if (scope_req && !scope_cap) begin
            scope_cap   <= 1'b1;
            scope_ready <= 1'b0;
            scope_wr    <= 8'd0;
            scope_div   <= 3'd0;
        end else if (scope_consume) begin
            scope_ready <= 1'b0;
        end else if (scope_cap) begin
            if (sample_tick) begin
                if (scope_div == 3'd7) begin
                    scope_div <= 3'd0;
                    scope_buf[scope_wr] <= scope_audio;
                    if (scope_wr == 8'd127) begin
                        scope_cap   <= 1'b0;
                        scope_ready <= 1'b1;
                    end else begin
                        scope_wr <= scope_wr + 1'b1;
                    end
                end else begin
                    scope_div <= scope_div + 1'b1;
                end
            end
        end
    end

    wire [31:0] ev_word = {
        frame_payload[evt_i*32 + 24 +: 8],
        frame_payload[evt_i*32 + 16 +: 8],
        frame_payload[evt_i*32 +  8 +: 8],
        frame_payload[evt_i*32 +  0 +: 8]
    };

    function [15:0] crc16_byte;
        input [15:0] c;
        input [7:0]  d;
        integer i;
        reg [15:0] x;
        begin
            x = c ^ {d, 8'h00};
            for (i = 0; i < 8; i = i + 1)
                x = x[15] ? ((x << 1) ^ 16'h1021) : (x << 1);
            crc16_byte = x;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st           <= C_IDLE;
            last_cmd     <= 8'd0;
            scope_req    <= 1'b0;
            scope_stream <= 1'b0;
            scope_single <= 1'b0;
            scope_burst  <= 1'b0;
            scope_consume<= 1'b0;
            scope_chunk  <= 5'd0;
            scope_send   <= 8'd0;
            scope_gap    <= 16'd0;
            status       <= 8'd0;
            err          <= 8'd0;
            wr_ptr       <= 12'd0;
            sum          <= 32'd0;
            save_wait    <= 28'd0;
            slot_sel     <= 4'd0;
            load_req     <= 1'b0;
            delete_req   <= 1'b0;
            evt_n        <= 6'd0;
            evt_i        <= 6'd0;
            frame_ack    <= 1'b0;
            song_wr_addr <= 12'd0;
            song_wr_data <= 32'd0;
            song_wr_en   <= 1'b0;
            song_len     <= 12'd0;
            song_play    <= 1'b0;
            song_stop    <= 1'b0;
            song_pause   <= 1'b0;
            tx_data      <= 8'd0;
            tx_start     <= 1'b0;
            crc_i        <= 5'd0;
            crc_lim      <= 5'd11;
            crc_v        <= 16'hFFFF;
            tx_i         <= 5'd0;
            tx_len       <= 5'd0;
            led_link     <= 1'b0;
            led_act      <= 1'b0;
            act_cnt      <= 21'd0;
            save_name    <= 128'd0;
            name_req     <= 1'b0;
            name_slot    <= 4'd0;
            name_part    <= 1'b0;
            rec_clear    <= 1'b0;
            rec_cmd      <= 1'b0;
            rec_slot     <= 4'd0;
            live_gate    <= 32'd0;
            live_vel     <= 256'd0;
            pitch_bend   <= 32'sd0;
            pc_vol       <= 5'd13;
            pc_vol_set   <= 1'b0;
            pc_timbre    <= 2'd1;
            pc_timbre_set<= 1'b0;
            pc_vib       <= 2'd0;
            pc_vib_set   <= 1'b0;
            pc_glide     <= 2'd0;
            pc_glide_set <= 1'b0;
            pc_chorus    <= 1'b0;
            pc_delay     <= 1'b0;
            // Piano defaults: same integer steps as top-level TA0/TD0/TR0.
            adsr_att     <= 16'd682;
            adsr_dec     <= 16'd1;
            adsr_sus     <= 16'd0;
            adsr_rel     <= 16'd4;
        end else begin
            // PC parameter writes are single-clock strobes.
            pc_timbre_set<= 1'b0;
            pc_vol_set   <= 1'b0;
            frame_ack    <= 1'b0;
            song_wr_en   <= 1'b0;
            song_play    <= 1'b0;
            song_stop    <= 1'b0;
            song_pause   <= 1'b0;
            name_req     <= 1'b0;
            rec_clear    <= 1'b0;
            rec_cmd      <= 1'b0;
            tx_start     <= 1'b0;
            save_req     <= 1'b0;
            load_req     <= 1'b0;
            delete_req   <= 1'b0;
            // 蓝牙活动灯：每帧点亮约 40ms
            if (frame_valid)
                act_cnt <= 21'd2_000_000;
            else if (act_cnt != 21'd0)
                act_cnt <= act_cnt - 1'b1;
            led_act  <= (act_cnt != 21'd0);
            led_link <= bt_state;

            case (st)
            //=================================================================
            C_IDLE: begin
                if (scope_consume)
                    scope_consume <= 1'b0;
                if (scope_req && (scope_cap || scope_ready))
                    scope_req <= 1'b0;
                if (scope_ready && !scope_stream) begin
                    scope_stream <= 1'b1;
                    scope_burst  <= 1'b1;
                    scope_chunk  <= 5'd0;
                    scope_send   <= 8'd0;
                    st           <= C_SCOPE_FILL;
                end else if (lib_play) begin
                    if (song_playing) begin
                        song_stop <= 1'b1;
                    end else begin
                        slot_sel  <= lib_slot;
                        song_len  <= 12'd0;
                        wr_ptr    <= 12'd0;
                        load_req  <= 1'b1;
                        save_wait <= 28'd0;
                        st        <= C_LIB_LOAD;
                    end
                end
                // 其他页 S2: 播放/停止当前已加载曲目
                if (play_key) begin
                    if (song_playing) begin
                        song_stop <= 1'b1;
                    end else if (ext_len != 12'd0 ||
                                 (song_len != 12'd0 && wr_ptr == song_len)) begin
                        song_play <= 1'b1;
                    end
                end
                if (frame_valid) begin
                    last_cmd <= frame_cmd;
                    status   <= 8'd0;
                    err      <= 8'd0;
                    frame_ack <= 1'b1;
                    pc_vib_set    <= 1'b0;
                    pc_glide_set  <= 1'b0;
                    pc_chorus_set <= 1'b0;
                    pc_delay_set  <= 1'b0;

                    case (frame_cmd)
                    //---------------------------------------------------------
                    8'h01: begin                       // PING
                        st <= C_REPLY;
                    end
                    //---------------------------------------------------------
                    8'h20: begin                       // SONG_BEGIN
                        rec_clear <= 1'b1;
                        song_len <= {frame_payload[11:8], frame_payload[7:0]};
                        wr_ptr   <= 12'd0;
                        sum      <= 32'd0;
                        song_stop <= 1'b1;
                        if (frame_len < 6'd2) begin
                            status <= 8'd1; err <= 8'd1;
                        end else if ({frame_payload[15:8], frame_payload[7:0]} > 16'd4095) begin
                            status <= 8'd1; err <= 8'd3;
                        end
                        st <= C_REPLY;
                    end
                    //---------------------------------------------------------
                    8'h21: begin                       // SONG_EVENTS
                        if (frame_len >= 6'd4 && frame_len[1:0] == 2'b00) begin
                            evt_n <= frame_len[5:2];
                            evt_i <= 6'd0;
                            st    <= C_EVENTS;
                            frame_ack <= 1'b0;      // 写完再 ack
                        end else begin
                            status <= 8'd1; err <= 8'd2;
                            st     <= C_REPLY;
                        end
                    end
                    //---------------------------------------------------------
                    8'h22: begin                       // SONG_END
                        if (frame_len < 6'd4) begin
                            status <= 8'd1; err <= 8'd1;
                        end else if (wr_ptr != song_len) begin
                            status <= 8'd1; err <= 8'd4;
                        end else if (sum != {frame_payload[31:24], frame_payload[23:16],
                                             frame_payload[15:8],  frame_payload[7:0]}) begin
                            status <= 8'd1; err <= 8'd5;
                        end
                        st <= C_REPLY;
                    end
                    //---------------------------------------------------------
                    8'h23: begin                       // PLAY
                        if (song_len != 12'd0 && wr_ptr == song_len) begin
                            song_play <= 1'b1;
                        end else if (ext_len != 12'd0) begin
                            song_play <= 1'b1;         // 播放 Flash 里已加载的曲目
                        end else begin
                            status <= 8'd1; err <= 8'd6;
                        end
                        st <= C_REPLY;
                    end
                    //---------------------------------------------------------
                    8'h24: begin                       // STOP
                        song_stop <= 1'b1;
                        st <= C_REPLY;
                    end
                    //---------------------------------------------------------
                    8'h25: begin                       // PAUSE (等同 STOP)
                        song_pause <= 1'b1;
                        st <= C_REPLY;
                    end
                    //---------------------------------------------------------
                    8'h40: begin                       // PC NOTE_ON: [note][vel]
                        if (frame_len >= 6'd2 && frame_payload[7:0] < 8'd32) begin
                            live_gate[frame_payload[4:0]] <= 1'b1;
                            live_vel[frame_payload[4:0]*8 +: 8] <=
                                (frame_payload[15:8] == 8'd0) ? 8'd1 :
                                 frame_payload[15:8];
                        end else begin
                            status <= 8'd1; err <= 8'd1;
                        end
                    end
                    //---------------------------------------------------------
                    8'h41: begin                       // PC NOTE_OFF: [note]
                        if (frame_len >= 6'd1 && frame_payload[7:0] < 8'd32)
                            live_gate[frame_payload[4:0]] <= 1'b0;
                        else begin
                            status <= 8'd1; err <= 8'd1;
                        end
                    end
                    //---------------------------------------------------------
                    8'h42: begin                       // PC ALL_NOTES_OFF
                        live_gate <= 32'd0;
                        pitch_bend <= 32'sd0;
                    end
                    //---------------------------------------------------------
                    8'h46: begin                       // PC PITCH_BEND (signed 32)
                        if (frame_len >= 6'd4)
                            pitch_bend <= $signed(frame_payload[31:0]);
                        else begin
                            status <= 8'd1; err <= 8'd1;
                        end
                    end
                    //---------------------------------------------------------
                    8'h43: begin                       // PC SET_VOLUME [0..19]
                        if (frame_len >= 6'd1 && frame_payload[7:0] < 8'd20) begin
                            pc_vol <= frame_payload[4:0];
                            pc_vol_set <= 1'b1;
                        end else begin
                            status <= 8'd1; err <= 8'd1;
                        end
                    end
                    //---------------------------------------------------------
                    8'h44: begin                       // PC SET_TIMBRE [1=piano, 2=guzheng, 3=xiao]
                        if (frame_len >= 6'd1 && frame_payload[7:0] >= 8'd1 && frame_payload[7:0] <= 8'd3) begin
                            pc_timbre <= frame_payload[1:0];
                            pc_timbre_set <= 1'b1;
                        end else begin
                            status <= 8'd1; err <= 8'd1;
                        end
                    end
                    //---------------------------------------------------------
                    8'h45: begin                       // PC SET_EFFECT [id][val]
                        if (frame_len >= 6'd2) begin
                            case (frame_payload[7:0])
                                8'd0: begin
                                    if (frame_payload[15:8] <= 8'd2) begin
                                        pc_vib <= frame_payload[9:8];
                                        pc_vib_set <= 1'b1;
                                    end else begin status <= 8'd1; err <= 8'd1; end
                                end
                                8'd1: begin
                                    if (frame_payload[15:8] <= 8'd2) begin
                                        pc_glide <= frame_payload[9:8];
                                        pc_glide_set <= 1'b1;
                                    end else begin status <= 8'd1; err <= 8'd1; end
                                end
                                8'd2: begin pc_chorus <= frame_payload[8]; pc_chorus_set <= 1'b1; end
                                8'd3: begin pc_delay  <= frame_payload[8]; pc_delay_set  <= 1'b1; end
                                default: begin status <= 8'd1; err <= 8'd1; end
                            endcase
                        end else begin
                            status <= 8'd1; err <= 8'd1;
                        end
                    end
                    //---------------------------------------------------------
                    8'h47: begin                       // PC SET_ADSR [att][dec][sus][rel]
                        if (frame_len >= 6'd8) begin
                            adsr_att <= frame_payload[15:0];
                            adsr_dec <= frame_payload[31:16];
                            adsr_sus <= frame_payload[47:32];
                            adsr_rel <= frame_payload[63:48];
                        end else begin
                            status <= 8'd1; err <= 8'd1;
                        end
                    end
                    //---------------------------------------------------------
                    8'h26: begin                       // SAVE 到指定槽位
                        song_stop <= 1'b1;
                        if (frame_len >= 6'd1)
                            slot_sel <= frame_payload[3:0];
                        for (k = 0; k < 16; k = k + 1)
                            save_name[k*8 +: 8] <= ((k+1) < frame_len) ?
                                                   frame_payload[(k+1)*8 +: 8] : 8'd0;
                        save_req  <= 1'b1;
                        save_wait <= 28'd0;
                        st        <= C_SAVE;
                    end
                    //---------------------------------------------------------
                    8'h27: begin                       // LOAD 指定槽位
                        rec_clear <= 1'b1;
                        song_stop <= 1'b1;
                        song_len  <= 12'd0;
                        wr_ptr    <= 12'd0;
                        if (frame_len >= 6'd1)
                            slot_sel <= frame_payload[3:0];
                        load_req  <= 1'b1;
                        save_wait <= 28'd0;
                        st        <= C_LOAD;
                    end
                    //---------------------------------------------------------
                    8'h28: begin                       // DELETE 指定槽位
                        song_stop <= 1'b1;
                        if (frame_len >= 6'd1)
                            slot_sel <= frame_payload[3:0];
                        delete_req<= 1'b1;
                        save_wait <= 28'd0;
                        st        <= C_DEL;
                    end
                    //---------------------------------------------------------
                    8'h48: begin                       // LIVE_STATUS 请求
                        st <= C_REPLY;
                    end
                    //---------------------------------------------------------
                    8'h49: begin                       // LIVE_PARAMS 请求
                        st <= C_REPLY;
                    end
                    //---------------------------------------------------------
                    8'h29: begin                       // LIST 曲库位图
                        st <= C_REPLY;
                    end
                    //---------------------------------------------------------
                    8'h2A: begin                       // NAME 读曲名: [slot][part]
                        if (frame_len < 6'd2) begin
                            status <= 8'd1; err <= 8'd1;
                            st     <= C_REPLY;
                        end else begin
                            name_slot <= frame_payload[3:0];
                            name_part <= frame_payload[8];
                            name_req  <= 1'b1;
                            save_wait <= 28'd0;
                            status    <= 8'd0; err <= 8'd0;
                            st        <= C_NAME;
                        end
                    end
                    //---------------------------------------------------------
                    8'h2C: begin                       // REC: [action][slot]
                        if (frame_len < 6'd1) begin
                            status <= 8'd1; err <= 8'd1;
                        end else begin
                            rec_slot <= (frame_len >= 6'd2) ?
                                        frame_payload[11:8] : 4'd0;
                            if ((frame_payload[7:0] != 8'd0 && !rec_active) ||
                                (frame_payload[7:0] == 8'd0 &&  rec_active))
                                rec_cmd <= 1'b1;
                            status <= 8'd0; err <= 8'd0;
                        end
                        st <= C_REPLY;
                    end
                    //---------------------------------------------------------
                    8'h30: begin                       // STATUS
                        st <= C_REPLY;
                    end
                    //---------------------------------------------------------
                    8'h50: begin                       // SCOPE_START
                        scope_req <= 1'b1;
                    end
                    //---------------------------------------------------------
                    8'h51: begin                       // SCOPE_CHUNK [chunk]
                        if (frame_len >= 6'd1 && frame_payload[7:0] <= 8'd21) begin
                            scope_chunk  <= frame_payload[4:0];
                            scope_send   <= frame_payload[4:0] * 8'd6;
                            scope_single <= 1'b1;
                            scope_burst  <= 1'b0;
                            scope_stream <= 1'b1;
                            st <= C_SCOPE_FILL;
                        end else begin
                            status <= 8'd1;
                            err    <= 8'd1;
                            st     <= C_REPLY;
                        end
                    end
                    //---------------------------------------------------------
                    default: begin
                        status <= 8'd1; err <= 8'd1;
                        st     <= C_REPLY;
                    end
                    endcase
                end
            end
            //=================================================================
            C_EVENTS: begin
                song_wr_en   <= 1'b1;
                song_wr_addr <= wr_ptr;
                song_wr_data <= ev_word;
                wr_ptr       <= wr_ptr + 1'b1;
                sum          <= sum + ev_word;
                evt_i        <= evt_i + 1'b1;

                if (evt_i + 1'b1 == evt_n) begin
                    frame_ack <= 1'b1;
                    st        <= C_GAP;
                end
            end
            //=================================================================
            C_SCOPE_FILL: begin
                rbuf[0]  <= 8'hAA;
                rbuf[1]  <= 8'h55;
                rbuf[2]  <= 8'hE2;
                rbuf[3]  <= 8'd13;
                rbuf[4]  <= {3'd0, scope_chunk};
                for (k = 0; k < 6; k = k + 1) begin
                    if (scope_send + {5'd0, k[2:0]} < 8'd128) begin
                        rbuf[5 + 2*k]     <= scope_buf[scope_send + k[2:0]][7:0];
                        rbuf[6 + 2*k]     <= scope_buf[scope_send + k[2:0]][15:8];
                    end else begin
                        rbuf[5 + 2*k]     <= 8'd0;
                        rbuf[6 + 2*k]     <= 8'd0;
                    end
                end
                scope_send <= scope_send + 8'd6;
                crc_i    <= 5'd2;
                crc_lim  <= 5'd16;
                crc_v    <= 16'hFFFF;
                st       <= C_CRC;
            end
            //=================================================================
            C_REPLY: begin
                rbuf[0]  <= 8'hAA;
                rbuf[1]  <= 8'h55;
                rbuf[2]  <= 8'hE0;
                rbuf[3]  <= 8'd8;
                rbuf[4]  <= last_cmd;
                rbuf[5]  <= status;
                if (last_cmd == 8'h30 && rec_active) begin
                    // STATUS while recording: bit7=REC, pos=events
                    rbuf[6]  <= 8'h80;
                    rbuf[7]  <= rec_len[7:0];
                    rbuf[8]  <= {4'd0, rec_len[11:8]};
                    rbuf[9]  <= 8'hFF;
                    rbuf[10] <= 8'h0F;
                    rbuf[11] <= err;
                end else if (last_cmd == 8'h48) begin
                    // LIVE_STATUS: keys[31:0], vel8, vol
                    rbuf[6]  <= keys[7:0];
                    rbuf[7]  <= keys[15:8];
                    rbuf[8]  <= keys[23:16];
                    rbuf[9]  <= keys[31:24];
                    rbuf[10] <= vel8;
                    rbuf[11] <= {3'd0, vol};
                end else if (last_cmd == 8'h49) begin
                    // LIVE_PARAMS: 音色/颤音/滑音/合唱/延迟
                    rbuf[6]  <= {2'd0, timbre, vib_sel, glide_sel};
                    rbuf[7]  <= {6'd0, chorus_on, delay_on};
                    rbuf[8]  <= 8'd0;
                    rbuf[9]  <= 8'd0;
                    rbuf[10] <= 8'd0;
                    rbuf[11] <= 8'd0;
                end else if (last_cmd == 8'h29) begin
                    // LIST: mask_lo, mask_hi, current, 0, 0, err
                    rbuf[6]  <= lib_mask[7:0];
                    rbuf[7]  <= lib_mask[15:8];
                    rbuf[8]  <= {4'd0, lib_current};
                    rbuf[9]  <= 8'd0;
                    rbuf[10] <= 8'd0;
                    rbuf[11] <= err;
                end else begin
                    rbuf[6]  <= {7'd0, song_playing};
                    rbuf[7]  <= song_pos[7:0];
                    rbuf[8]  <= {4'd0, song_pos[11:8]};
                    rbuf[9]  <= (song_len != 12'd0) ? song_len[7:0]  : ext_len[7:0];
                    rbuf[10] <= (song_len != 12'd0) ? {4'd0, song_len[11:8]} :
                                                        {4'd0, ext_len[11:8]};
                    rbuf[11] <= err;
                end
                crc_i    <= 5'd2;
                crc_lim  <= 5'd11;
                crc_v    <= 16'hFFFF;
                st       <= C_CRC;
            end
            //=================================================================
            C_CRC: begin
                if (crc_i <= crc_lim) begin
                    crc_v <= crc16_byte(crc_v, rbuf[crc_i]);
                    crc_i <= crc_i + 1'b1;
                end else begin
                    rbuf[crc_lim + 1] <= crc_v[7:0];
                    rbuf[crc_lim + 2] <= crc_v[15:8];
                    tx_len   <= crc_lim + 5'd3;
                    tx_i     <= 5'd0;
                    st       <= C_TX;
                end
            end
            //=================================================================
            C_TX: begin
                tx_data  <= rbuf[tx_i];
                tx_start <= 1'b1;
                st       <= C_TXW;
            end
            C_TXW: begin
                if (tx_busy)
                    st <= C_TXD;
            end
            C_TXD: begin
                if (!tx_busy) begin
                    if (tx_i + 1'b1 >= tx_len) begin
                        if (scope_stream) begin
                            if (scope_burst && scope_chunk != 5'd21) begin
                                scope_chunk <= scope_chunk + 1'b1;
                                scope_gap   <= 16'd99_999;    // 2ms
                                st <= C_SCOPE_GAP;
                            end else begin
                                scope_stream <= 1'b0;
                                scope_burst  <= 1'b0;
                                scope_single <= 1'b0;
                                scope_consume<= scope_burst;
                                scope_gap    <= 16'd99_999;
                                st <= C_SCOPE_GAP;
                            end
                        end else begin
                            st <= C_IDLE;
                        end
                    end else begin
                        tx_i <= tx_i + 1'b1;
                        st   <= C_TX;
                    end
                end
            end
            //=================================================================
            C_SCOPE_GAP: begin
                if (scope_gap == 16'd0)
                    st <= scope_burst ? C_SCOPE_FILL : C_IDLE;
                else
                    scope_gap <= scope_gap - 1'b1;
            end
            //=================================================================
            C_LIB_LOAD: begin
                load_req <= 1'b0;
                if (load_done) begin
                    song_play <= 1'b1;
                    st        <= C_REPLY;
                end else if (save_wait >= 28'd100_000_000) begin
                    status <= 8'd1; err <= 8'd11;
                    st     <= C_REPLY;
                end else begin
                    save_wait <= save_wait + 1'b1;
                end
            end
            //=================================================================
            C_NAME: begin
                if (name_done) begin
                    if (!name_valid) begin
                        status <= 8'd1; err <= 8'd12;
                        st     <= C_REPLY;
                    end else begin
                        rbuf[0] <= 8'hAA;
                        rbuf[1] <= 8'h55;
                        rbuf[2] <= 8'hE1;
                        rbuf[3] <= 8'd8;
                        for (k = 0; k < 8; k = k + 1)
                            rbuf[4+k] <= name_part ? name_data[64+k*8 +: 8]
                                                   : name_data[k*8 +: 8];
                        crc_i   <= 5'd2;
                        crc_lim <= 5'd11;
                        crc_v   <= 16'hFFFF;
                        st      <= C_CRC;
                    end
                end else if (save_wait >= 28'd100_000_000) begin
                    status <= 8'd1; err <= 8'd12;
                    st     <= C_REPLY;
                end else begin
                    save_wait <= save_wait + 1'b1;
                end
            end
            //=================================================================
            C_LOAD: begin
                load_req <= 1'b0;
                if (load_done) begin
                    st <= C_REPLY;
                end else if (save_wait >= 28'd100_000_000) begin
                    status <= 8'd1; err <= 8'd9;
                    st     <= C_REPLY;
                end else begin
                    save_wait <= save_wait + 1'b1;
                end
            end
            //=================================================================
            C_DEL: begin
                delete_req <= 1'b0;
                if (delete_done) begin
                    st <= C_REPLY;
                end else if (save_wait >= 28'd100_000_000) begin
                    status <= 8'd1; err <= 8'd10;
                    st     <= C_REPLY;
                end else begin
                    save_wait <= save_wait + 1'b1;
                end
            end
            //=================================================================
            C_SAVE: begin
                save_req <= 1'b0;
                if (save_done) begin
                    if (save_err) begin
                        status <= 8'd1;
                        err    <= 8'd7;
                    end
                    st <= C_REPLY;
                end else if (save_wait >= 28'd100_000_000) begin
                    // 2 秒还没完成，按超时回复
                    status <= 8'd1;
                    err    <= 8'd8;
                    st     <= C_REPLY;
                end else begin
                    save_wait <= save_wait + 1'b1;
                end
            end
            //=================================================================
            // frame_ack 是寄存器输出，frame_valid 要下一拍才清零；
            // 这里多等一拍，避免 C_IDLE 把同一帧再处理一次。
            C_GAP: begin
                st <= C_IDLE;
            end
            //=================================================================
            default: st <= C_IDLE;
            endcase
        end
    end

endmodule
