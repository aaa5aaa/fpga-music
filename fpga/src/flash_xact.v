//=============================================================================
// flash_xact.v — W25Q64 一次 SPI 事务
//
//   start 后: CS 拉低 -> 发 hdr_len 个字节(hdr MSB 先) -> 发/收 nbytes 字节
//   mode=0: 从 buf 读数据发出去 (页编程)
//   mode=1: 收到的数据写入 buf (读数据)
//   结束拉高 CS，done 单周期脉冲
//=============================================================================
`timescale 1ns/1ps

module flash_xact (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [31:0] hdr,       // {cmd, addr[23:0]}
    input  wire [2:0]  hdr_len,   // 1..4
    input  wire [15:0] nbytes,
    input  wire        mode,      // 0=写(从 buf), 1=读(到 buf)
    output reg  [7:0]  buf_raddr,
    input  wire [7:0]  buf_rdata,
    output reg         buf_we,
    output reg  [7:0]  buf_waddr,
    output reg  [7:0]  buf_wdata,
    output reg         cs,
    output wire        sclk,
    output wire        mosi,
    input  wire        miso,
    output reg         busy,
    output reg         done
);

    localparam [3:0] S_IDLE  = 4'd0,
                     S_HDR_S = 4'd1,
                     S_HDR_W = 4'd2,
                     S_DW0   = 4'd3,
                     S_DW1   = 4'd4,
                     S_DW2   = 4'd5,
                     S_DR0   = 4'd6,
                     S_DR1   = 4'd7,
                     S_CSHI  = 4'd8,
                     S_DONE  = 4'd9;

    reg [3:0]  st;
    reg [31:0] hdr_sh;
    reg [2:0]  hdr_cnt;
    reg [15:0] nbytes_r;
    reg [15:0] data_cnt;
    reg        mode_r;
    reg        spi_start;
    reg [7:0]  spi_tx;
    wire [7:0] spi_rx;
    wire       spi_done;

    spi_byte u_spi (
        .clk   (clk),
        .rst_n (rst_n),
        .start (spi_start),
        .tx    (spi_tx),
        .rx    (spi_rx),
        .done  (spi_done),
        .sclk  (sclk),
        .mosi  (mosi),
        .miso  (miso)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st        <= S_IDLE;
            cs        <= 1'b1;
            spi_start <= 1'b0;
            spi_tx    <= 8'd0;
            hdr_sh    <= 32'd0;
            hdr_cnt   <= 3'd0;
            nbytes_r  <= 16'd0;
            data_cnt  <= 16'd0;
            mode_r    <= 1'b0;
            buf_raddr <= 8'd0;
            buf_we    <= 1'b0;
            buf_waddr <= 8'd0;
            buf_wdata <= 8'd0;
            busy      <= 1'b0;
            done      <= 1'b0;
        end else begin
            spi_start <= 1'b0;
            buf_we    <= 1'b0;
            done      <= 1'b0;

            case (st)
            //-----------------------------------------------------------------
            S_IDLE: begin
                cs <= 1'b1;
                if (start) begin
                    cs       <= 1'b0;
                    hdr_sh   <= hdr;
                    hdr_cnt  <= hdr_len - 1'b1;
                    nbytes_r <= nbytes;
                    data_cnt <= 16'd0;
                    mode_r   <= mode;
                    busy     <= 1'b1;
                    st       <= S_HDR_S;
                end
            end
            //-----------------------------------------------------------------
            S_HDR_S: begin
                spi_tx    <= hdr_sh[31:24];
                spi_start <= 1'b1;
                st        <= S_HDR_W;
            end
            //-----------------------------------------------------------------
            S_HDR_W: begin
                if (spi_done) begin
                    hdr_sh <= {hdr_sh[23:0], 8'd0};
                    if (hdr_cnt == 3'd0) begin
                        if (nbytes_r == 16'd0)
                            st <= S_CSHI;
                        else if (mode_r)
                            st <= S_DR0;
                        else
                            st <= S_DW0;
                    end else begin
                        hdr_cnt <= hdr_cnt - 1'b1;
                        st      <= S_HDR_S;
                    end
                end
            end
            //-----------------------------------------------------------------
            // 页编程: 从 buf 取字节
            S_DW0: begin
                buf_raddr <= data_cnt[7:0];
                st        <= S_DW1;
            end
            //-----------------------------------------------------------------
            S_DW1: begin
                spi_tx    <= buf_rdata;
                spi_start <= 1'b1;
                st        <= S_DW2;
            end
            //-----------------------------------------------------------------
            S_DW2: begin
                if (spi_done) begin
                    if (data_cnt + 1'b1 >= nbytes_r)
                        st <= S_CSHI;
                    else begin
                        data_cnt <= data_cnt + 1'b1;
                        st       <= S_DW0;
                    end
                end
            end
            //-----------------------------------------------------------------
            // 读数据: 写入 buf
            S_DR0: begin
                spi_tx    <= 8'hFF;
                spi_start <= 1'b1;
                st        <= S_DR1;
            end
            //-----------------------------------------------------------------
            S_DR1: begin
                if (spi_done) begin
                    buf_we    <= 1'b1;
                    buf_waddr <= data_cnt[7:0];
                    buf_wdata <= spi_rx;
                    if (data_cnt + 1'b1 >= nbytes_r)
                        st <= S_CSHI;
                    else begin
                        data_cnt <= data_cnt + 1'b1;
                        st       <= S_DR0;
                    end
                end
            end
            //-----------------------------------------------------------------
            S_CSHI: begin
                cs <= 1'b1;
                st <= S_DONE;
            end
            //-----------------------------------------------------------------
            S_DONE: begin
                busy <= 1'b0;
                done <= 1'b1;
                st   <= S_IDLE;
            end
            //-----------------------------------------------------------------
            default: st <= S_IDLE;
            endcase
        end
    end

endmodule
