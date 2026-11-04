module control_keys #(
    parameter CLOCK_HZ = 50000000
) (
    input wire clk,
    input wire reset_n,
    input wire [7:0] buttons_n,
    output reg [7:0] press_pulse
);
    reg [7:0] stage1, stage2, stable;
    reg [19:0] timer;
    reg initialized;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            stage1 <= 8'hff;
            stage2 <= 8'hff;
            stable <= 8'hff;
            press_pulse <= 0;
            timer <= 0;
            initialized <= 1'b0;
        end else begin
            stage1 <= buttons_n;
            stage2 <= stage1;
            press_pulse <= 0;
            if (timer == CLOCK_HZ / 100 - 1) begin
                timer <= 0;
                // Treat the first settled switch sample as the power-on baseline.
                // A low SW0 at reset must not turn the initial piano into guzheng.
                if (initialized) press_pulse <= stable & ~stage2;
                else initialized <= 1'b1;
                stable <= stage2;
            end else timer <= timer + 1'b1;
        end
    end
endmodule
