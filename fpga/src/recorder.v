//=============================================================================
// recorder.v — 键盘事件录音
//
//   S3 按一下开始，再按一下停止。
//   记录格式与蓝牙曲谱一致: {delta_ms[15:0], note[7:0], vel[8]}
//   录音时停播放；停止时给仍按住的键补 note-off，再置 rec_done。
//   最多 4095 个事件。
//=============================================================================
`timescale 1ns/1ps

module recorder #(
    parameter integer CLK_HZ = 50_000_000
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        toggle,      // S3 按下脉冲: 开始/停止
    input  wire        clear,       // 蓝牙新曲/加载时清空
    input  wire [31:0] keys,        // 消抖后的 32 键, 1=按下
    input  wire [7:0]  vel8,        // 当前 FSR 力度
    input  wire [31:0] live_gate,   // PC 实时音符
    input  wire [255:0] live_vel,   // PC 实时力度

    output reg  [11:0] wr_addr,
    output reg  [31:0] wr_data,
    output reg         wr_en,
    output reg  [11:0] rec_len,
    output reg         rec_active,
    output reg         rec_done,
    output reg         rec_full
);

    localparam integer MS_CNT = CLK_HZ / 1000;

    reg [15:0] ms_div;
    reg [31:0] ms_now;
    wire       ms_tick = (MS_CNT <= 1) || (ms_div >= MS_CNT - 1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ms_div <= 16'd0;
            ms_now <= 32'd0;
        end else if (ms_tick) begin
            ms_div <= 16'd0;
            ms_now <= ms_now + 1'b1;
        end else begin
            ms_div <= ms_div + 1'b1;
        end
    end

    reg [31:0] keys_prev;
    reg [31:0] pend_on;
    reg [31:0] pend_off;
    reg [31:0] ms_last;
    reg        stopping;

    integer i;
    reg        found;
    reg        sel_off;
    reg [4:0]  sel_note;

    // 先处理 note-off，再处理 note-on
    always @* begin
        found    = 1'b0;
        sel_off  = 1'b0;
        sel_note = 5'd0;
        for (i = 0; i < 32; i = i + 1) begin
            if (!found && pend_off[i]) begin
                found    = 1'b1;
                sel_off  = 1'b1;
                sel_note = i[4:0];
            end
        end
        if (!found) begin
            for (i = 0; i < 32; i = i + 1) begin
                if (!found && pend_on[i]) begin
                    found    = 1'b1;
                    sel_off  = 1'b0;
                    sel_note = i[4:0];
                end
            end
        end
    end

    wire [31:0] delta_raw = ms_now - ms_last;
    wire [15:0] delta_ms  = (delta_raw > 32'd65535) ? 16'hFFFF : delta_raw[15:0];
    wire [31:0] gate_all = keys | live_gate;
    wire [7:0]  live_byte = live_vel[sel_note*8 +: 8];
    wire [7:0]  raw_vel = live_gate[sel_note] ? live_byte : vel8;
    wire [7:0]  vel_use = (raw_vel == 8'd0) ? 8'd1 : raw_vel;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_addr    <= 12'd0;
            wr_data    <= 32'd0;
            wr_en      <= 1'b0;
            rec_len    <= 12'd0;
            rec_active <= 1'b0;
            rec_done   <= 1'b0;
            rec_full   <= 1'b0;
            keys_prev  <= 32'd0;
            pend_on    <= 32'd0;
            pend_off   <= 32'd0;
            ms_last    <= 32'd0;
            stopping   <= 1'b0;
        end else begin
            wr_en <= 1'b0;

            if (clear) begin
                wr_addr    <= 12'd0;
                rec_len    <= 12'd0;
                rec_active <= 1'b0;
                rec_done   <= 1'b0;
                rec_full   <= 1'b0;
                stopping   <= 1'b0;
                pend_on    <= 32'd0;
                pend_off   <= 32'd0;
                keys_prev  <= gate_all;
                ms_last    <= ms_now;
            end else if (toggle) begin
                if (rec_active) begin
                    if (!stopping) begin
                        // 停止：给仍按住的键补 note-off，等清空后再 done
                        stopping <= 1'b1;
                        pend_off <= pend_off | gate_all;
                    end
                end else begin
                    rec_active <= 1'b1;
                    rec_done   <= 1'b0;
                    rec_full   <= 1'b0;
                    rec_len    <= 12'd0;
                    wr_addr    <= 12'd0;
                    stopping   <= 1'b0;
                    pend_on    <= 32'd0;
                    pend_off   <= 32'd0;
                    keys_prev  <= gate_all;
                    ms_last    <= ms_now;
                end
            end else if (rec_active) begin
                // 按键沿检测（50MHz 扫描，时间戳按 1ms 计）
                if (gate_all != keys_prev) begin
                    pend_on  <= pend_on  | ( gate_all & ~keys_prev);
                    pend_off <= pend_off | (~gate_all &  keys_prev);
                    keys_prev <= gate_all;
                end

                if (found) begin
                    if (rec_len < 12'd4095) begin
                        wr_addr <= rec_len;
                        wr_data <= {delta_ms, {3'd0, sel_note},
                                    sel_off ? 8'd0 : vel_use};
                        wr_en   <= 1'b1;
                        rec_len <= rec_len + 1'b1;
                        ms_last <= ms_now;
                        if (sel_off) pend_off[sel_note] <= 1'b0;
                        else         pend_on [sel_note] <= 1'b0;
                    end else begin
                        rec_full   <= 1'b1;
                        rec_active <= 1'b0;
                        rec_done   <= 1'b1;
                        stopping   <= 1'b0;
                        pend_on    <= 32'd0;
                        pend_off   <= 32'd0;
                    end
                end else if (stopping && pend_on == 32'd0 && pend_off == 32'd0) begin
                    rec_active <= 1'b0;
                    rec_done   <= 1'b1;
                    stopping   <= 1'b0;
                end
            end
        end
    end

endmodule
