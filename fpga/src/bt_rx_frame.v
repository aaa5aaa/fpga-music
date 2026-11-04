//=============================================================================
// bt_rx_frame.v — 蓝牙/串口帧解析
//
//   帧格式:  AA 55 | CMD(1) | LEN(1) | PAYLOAD(LEN) | CRC16(2, 低字节在前)
//   CRC16:   CCITT-FALSE, poly=0x1021, init=0xFFFF, 覆盖 CMD/LEN/PAYLOAD
//   LEN:     0..63
//
//   解析出一帧后 frame_valid=1 并保持，直到上层给 frame_ack 才释放。
//   这样上层可以从容处理，不会在解析过程中被下一帧覆盖。
//=============================================================================
`timescale 1ns/1ps

module bt_rx_frame (
    input  wire         clk,
    input  wire         rst_n,

    input  wire [7:0]   rx_data,
    input  wire         rx_valid,

    output reg          frame_valid,
    output reg  [7:0]   frame_cmd,
    output reg  [5:0]   frame_len,
    output reg  [511:0] frame_payload,
    input  wire         frame_ack
);

    localparam S_AA   = 3'd0,
               S_55   = 3'd1,
               S_CMD  = 3'd2,
               S_LEN  = 3'd3,
               S_PAY  = 3'd4,
               S_CRCL = 3'd5,
               S_CRCH = 3'd6;

    reg [2:0]  st;
    reg [7:0]  cmd;
    reg [5:0]  len;
    reg [5:0]  idx;
    reg [15:0] crc;
    reg [15:0] crc_lo;

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
            st            <= S_AA;
            frame_valid   <= 1'b0;
            frame_cmd     <= 8'd0;
            frame_len     <= 6'd0;
            frame_payload <= 512'd0;
            cmd           <= 8'd0;
            len           <= 6'd0;
            idx           <= 6'd0;
            crc           <= 16'hFFFF;
            crc_lo        <= 16'd0;
        end else begin
            if (frame_ack)
                frame_valid <= 1'b0;

            if (rx_valid && !frame_valid) begin
                case (st)
                    S_AA: begin
                        if (rx_data == 8'hAA) st <= S_55;
                    end
                    S_55: begin
                        if (rx_data == 8'h55)      st <= S_CMD;
                        else if (rx_data != 8'hAA) st <= S_AA;
                    end
                    S_CMD: begin
                        cmd <= rx_data;
                        crc <= crc16_byte(16'hFFFF, rx_data);
                        st  <= S_LEN;
                    end
                    S_LEN: begin
                        len <= rx_data[5:0];
                        idx <= 6'd0;
                        crc <= crc16_byte(crc, rx_data);
                        if (rx_data[7:6] != 2'b00)
                            st <= S_AA;
                        else if (rx_data[5:0] == 6'd0)
                            st <= S_CRCL;
                        else
                            st <= S_PAY;
                    end
                    S_PAY: begin
                        frame_payload[idx*8 +: 8] <= rx_data;
                        crc <= crc16_byte(crc, rx_data);
                        idx <= idx + 1'b1;
                        if (idx + 1'b1 == len)
                            st <= S_CRCL;
                    end
                    S_CRCL: begin
                        crc_lo[7:0] <= rx_data;
                        st <= S_CRCH;
                    end
                    S_CRCH: begin
                        crc_lo[15:8] <= rx_data;
                        if ({rx_data, crc_lo[7:0]} == crc) begin
                            frame_valid <= 1'b1;
                            frame_cmd   <= cmd;
                            frame_len   <= len;
                        end
                        st <= S_AA;
                    end
                    default: st <= S_AA;
                endcase
            end
        end
    end

endmodule
