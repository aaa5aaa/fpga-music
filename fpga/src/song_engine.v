//=============================================================================
// song_engine.v — 曲谱存储 + 播放器
//
//   BSRAM: 4096 x 32bit，每个事件 4 字节：
//       [31:16] delta_ms   (相对上一个事件的时间，单位 ms)
//       [15:8]  note       (0..31)
//       [7:0]   velocity   (0 = note off, 1..255 = note on)
//
//   播放: 1ms tick；delta 减到 0 就应用事件；delta=0 的连续事件
//         （和弦）会在同一毫秒内连续处理完，不会把和弦拆成 8ms。
//
//   注意: 第一版 pause 等同 stop（不做断点续播），需要续播请用 stop/play。
//=============================================================================
`timescale 1ns/1ps

module song_engine (
    input  wire         clk,
    input  wire         rst_n,

    //---- 写入端口（来自 bt_cmd 或 flash_song）----
    input  wire         wr_en,
    input  wire [11:0]  wr_addr,
    input  wire [31:0]  wr_data,

    //---- 外部读口（保存到 Flash 时用）----
    input  wire [11:0]  ext_addr,
    input  wire         ext_en,
    output wire [31:0]  ext_data,

    //---- 控制 ----
    input  wire [11:0]  song_len,
    input  wire         play,
    input  wire         stop,
    input  wire         pause,

    //---- 状态 ----
    output reg  [11:0]  pos,
    output reg          playing,

    //---- 发声控制 ----
    output reg  [31:0]  gate,
    output reg  [255:0] vel_flat
);

    localparam S_IDLE  = 3'd0,
               S_RD    = 3'd1,
               S_CHECK = 3'd2,
               S_WAIT  = 3'd3,
               S_APPLY = 3'd4;

    reg [31:0] mem [0:4095];

    reg [2:0]  st;
    reg [31:0] data_r;
    reg [11:0] rd_addr;
    reg [31:0] cur;
    reg [15:0] cur_delta;

    reg [15:0] tick_cnt;
    wire       tick = (tick_cnt == 16'd49_999);

    wire [4:0] ev_note = cur[12:8];
    wire [7:0] ev_vel  = cur[7:0];

    //---- BSRAM: 一个写口 + 一个读口（播放/外部读共用）----
    wire [11:0] mem_raddr = ext_en ? ext_addr : rd_addr;

    always @(posedge clk) begin
        if (wr_en)
            mem[wr_addr] <= wr_data;
        data_r <= mem[mem_raddr];
    end

    assign ext_data = data_r;

    //---- 1ms tick ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            tick_cnt <= 16'd0;
        else if (tick)
            tick_cnt <= 16'd0;
        else
            tick_cnt <= tick_cnt + 1'b1;
    end

    //---- 播放状态机 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st         <= S_IDLE;
            pos        <= 12'd0;
            playing    <= 1'b0;
            gate       <= 32'd0;
            vel_flat   <= 256'd0;
            rd_addr    <= 12'd0;
            cur        <= 32'd0;
            cur_delta  <= 16'd0;
        end else if (stop || pause) begin
            st       <= S_IDLE;
            playing  <= 1'b0;
            pos      <= 12'd0;
            gate     <= 32'd0;
            vel_flat <= 256'd0;
        end else if (play) begin
            if (song_len != 12'd0) begin
                pos      <= 12'd0;
                rd_addr  <= 12'd0;
                gate     <= 32'd0;
                vel_flat <= 256'd0;
                playing  <= 1'b1;
                st       <= S_RD;
            end
        end else begin
            case (st)
                S_IDLE: begin
                    playing <= 1'b0;
                end

                // 地址已在上一步给出，这里等一个时钟让 data_r 更新
                S_RD: begin
                    st <= S_CHECK;
                end

                S_CHECK: begin
                    cur       <= data_r;
                    cur_delta <= data_r[31:16];
                    if (data_r[31:16] == 16'd0)
                        st <= S_APPLY;
                    else
                        st <= S_WAIT;
                end

                S_WAIT: begin
                    if (tick) begin
                        if (cur_delta <= 16'd1)
                            st <= S_APPLY;
                        else
                            cur_delta <= cur_delta - 1'b1;
                    end
                end

                S_APPLY: begin
                    if (ev_vel != 8'd0) begin
                        gate[ev_note]            <= 1'b1;
                        vel_flat[ev_note*8 +: 8] <= ev_vel;
                    end else begin
                        gate[ev_note]            <= 1'b0;
                        vel_flat[ev_note*8 +: 8] <= 8'd0;
                    end

                    pos <= pos + 1'b1;

                    if (pos + 1'b1 >= song_len) begin
                        playing  <= 1'b0;
                        gate     <= 32'd0;
                        vel_flat <= 256'd0;
                        st       <= S_IDLE;
                    end else begin
                        rd_addr <= pos + 1'b1;
                        st      <= S_RD;
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
