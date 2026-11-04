// note_turning.v — 音高增量表 (fs = 48.828kHz, 32 个半音, 从 C4 起)
// inc = round(f * 2^24 / fs),  f = 261.6256 * 2^(n/12)
`timescale 1ns/1ps

module note_tuning (
    input  wire [4:0] note,
    output reg  [23:0] tuning
);
    always @(*) begin
        case (note)
            5'd0 : tuning = 24'd89894;
            5'd1 : tuning = 24'd95239;
            5'd2 : tuning = 24'd100902;
            5'd3 : tuning = 24'd106902;
            5'd4 : tuning = 24'd113259;
            5'd5 : tuning = 24'd119994;
            5'd6 : tuning = 24'd127129;
            5'd7 : tuning = 24'd134689;
            5'd8 : tuning = 24'd142698;
            5'd9 : tuning = 24'd151183;
            5'd10: tuning = 24'd160173;
            5'd11: tuning = 24'd169697;
            5'd12: tuning = 24'd179788;
            5'd13: tuning = 24'd190478;
            5'd14: tuning = 24'd201805;
            5'd15: tuning = 24'd213805;
            5'd16: tuning = 24'd226518;
            5'd17: tuning = 24'd239988;
            5'd18: tuning = 24'd254258;
            5'd19: tuning = 24'd269377;
            5'd20: tuning = 24'd285395;
            5'd21: tuning = 24'd302366;
            5'd22: tuning = 24'd320345;
            5'd23: tuning = 24'd339394;
            5'd24: tuning = 24'd359575;
            5'd25: tuning = 24'd380957;
            5'd26: tuning = 24'd403610;
            5'd27: tuning = 24'd427610;
            5'd28: tuning = 24'd453037;
            5'd29: tuning = 24'd479976;
            5'd30: tuning = 24'd508516;
            5'd31: tuning = 24'd538754;
            default: tuning = 24'd0;
        endcase
    end
endmodule
