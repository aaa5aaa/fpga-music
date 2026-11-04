//=============================================================================
// spi_byte.v — 8bit SPI 单字节收发 (mode 0, 50MHz/8 = 6.25MHz)
//=============================================================================
`timescale 1ns/1ps

module spi_byte (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,
    input  wire [7:0] tx,
    output reg  [7:0] rx,
    output reg        done,
    output reg        sclk,
    output reg        mosi,
    input  wire       miso
);

    reg        busy;
    reg [2:0]  ph;
    reg [2:0]  bitcnt;
    reg [7:0]  sh;
    reg [7:0]  rxs;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy  <= 1'b0;
            done  <= 1'b0;
            sclk  <= 1'b0;
            mosi  <= 1'b0;
            ph    <= 3'd0;
            bitcnt<= 3'd0;
            sh    <= 8'd0;
            rxs   <= 8'd0;
            rx    <= 8'd0;
        end else begin
            done <= 1'b0;

            if (!busy) begin
                if (start) begin
                    busy   <= 1'b1;
                    sh     <= tx;
                    rxs    <= 8'd0;
                    bitcnt <= 3'd0;
                    ph     <= 3'd0;
                    sclk   <= 1'b0;
                    mosi   <= tx[7];
                end
            end else begin
                case (ph)
                3'd0: begin
                    sclk <= 1'b0;
                    mosi <= sh[7];
                    ph   <= 3'd1;
                end
                3'd1, 3'd2, 3'd3: ph <= ph + 1'b1;
                3'd4: begin
                    sclk <= 1'b1;
                    rxs  <= {rxs[6:0], miso};
                    ph   <= 3'd5;
                end
                3'd5, 3'd6: ph <= ph + 1'b1;
                default: begin  // 3'd7
                    sclk <= 1'b0;
                    sh   <= {sh[6:0], 1'b0};
                    ph   <= 3'd0;
                    if (bitcnt == 3'd7) begin
                        busy <= 1'b0;
                        done <= 1'b1;
                        rx   <= rxs;
                    end else begin
                        bitcnt <= bitcnt + 1'b1;
                    end
                end
                endcase
            end
        end
    end

endmodule
