//=============================================================================
// audio_effects.v  —  延迟/合唱  (v4: 延迟扩到 327ms, 合唱加深)
//
//   延迟线: 16384 x 16bit BSRAM (约 15 块)
//     ECHO_DLY   = 16000 点 ≈ 327.7ms @ 48.828kHz
//     CHORUS_DLY = 180 点 (3.7ms) + LFO 0..120 点 (最深约 6.1ms)
//
//   上电后前 16384 个样点只写干声、输出干声, 等延迟线填满再启用效果,
//   避免读到未初始化/反馈垃圾.
//
//   两个效果都关时组合直通, 不依赖状态机.
//=============================================================================
`timescale 1ns/1ps

module audio_effects (
    input  wire               clk,
    input  wire               reset_n,
    input  wire               sample_tick,
    input  wire               delay_on,     // 延迟 独立开关
    input  wire               chorus_on,    // 合唱 独立开关
    input  wire signed [15:0] dry_sample,
    output wire signed [15:0] wet_sample
);

    localparam [13:0] ECHO_DLY   = 14'd16000;   // ≈327.7ms
    localparam [13:0] CHORUS_DLY = 14'd1000;    // 20.5ms (3.7ms 是镶边, 不是合唱)

    reg signed [15:0] delay_memory [0:16383];
    reg [13:0] write_address;
    reg [14:0] samples_written;
    reg [8:0]  modulation;              // 0..120
    reg        modulation_direction;
    reg [8:0]  modulation_timer;

    reg signed [15:0] echo_r, chorus_r;
    reg [1:0]  phase;
    reg signed [17:0] mixed;
    reg signed [15:0] wet_fx;

    wire [13:0] echo_addr   = write_address - ECHO_DLY;
    wire [13:0] chorus_addr = write_address - (CHORUS_DLY + {1'b0, modulation});

    wire signed [17:0] echo_mix   = delay_on  ? (echo_r   >>> 1) : 18'sd0;
    wire signed [17:0] chorus_mix = chorus_on ? (chorus_r >>> 1) : 18'sd0;

    always @(*) begin
        mixed = dry_sample + echo_mix + chorus_mix;
    end

    //-------------------------------------------------------------------------
    // 每样点 3 拍: 读回声 -> 读合唱 -> 写延迟线/算输出
    //-------------------------------------------------------------------------
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            write_address        <= 14'd0;
            samples_written      <= 15'd0;
            modulation           <= 9'd0;
            modulation_direction <= 1'b0;
            modulation_timer     <= 9'd0;
            phase                <= 2'd0;
            echo_r               <= 16'd0;
            chorus_r             <= 16'd0;
            wet_fx               <= 16'd0;
        end else begin
            case (phase)
            //-------------------------------------------------------------
            2'd0: begin
                if (sample_tick) phase <= 2'd1;
            end
            //-------------------------------------------------------------
            2'd1: begin
                echo_r <= delay_memory[echo_addr];
                phase  <= 2'd2;
            end
            //-------------------------------------------------------------
            2'd2: begin
                chorus_r <= delay_memory[chorus_addr];
                phase    <= 2'd3;
            end
            //-------------------------------------------------------------
            2'd3: begin
                // 前 16384 点只写干声，不把反馈写进去
                if (samples_written < 15'd16384)
                    delay_memory[write_address] <= dry_sample;
                else
                    delay_memory[write_address] <= dry_sample + (echo_r >>> 2);

                write_address <= write_address + 1'b1;
                if (samples_written < 15'd16384)
                    samples_written <= samples_written + 1'b1;

                if (samples_written < 15'd16384)  wet_fx <= dry_sample;
                else if (mixed > 18'sd32767)      wet_fx <= 16'sd32767;
                else if (mixed < -18'sd32768)     wet_fx <= -16'sd32768;
                else                              wet_fx <= mixed[15:0];

                // 合唱 LFO: 0..120, 每 200 个样点一步, 约 1Hz
                if (modulation_timer == 9'd99) begin
                    modulation_timer <= 9'd0;
                    if (modulation == 9'd0)   modulation_direction <= 1'b0;
                    if (modulation == 9'd300) modulation_direction <= 1'b1;
                    if (modulation_direction) modulation <= modulation - 1'b1;
                    else                      modulation <= modulation + 1'b1;
                end else begin
                    modulation_timer <= modulation_timer + 1'b1;
                end
                phase <= 2'd0;
            end
            default: phase <= 2'd0;
            endcase
        end
    end

    // 两个效果都关时组合直通
    assign wet_sample = (!delay_on && !chorus_on) ? dry_sample : wet_fx;

endmodule
