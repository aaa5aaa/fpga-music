//=============================================================================
// flash_song.v — 单曲存储/加载（W25Q64）
//
//   布局:
//     0x000000  8 字节元数据: 'A','C','G','7', len_lo, len_hi, 0, 0
//     0x001000  4096 个事件槽位 (16KB, 64 页 x 256B)
//
//   保存: 擦除扇区 0~4 -> 64 页编程 -> 写元数据
//   上电: 读元数据, 有效则读回 64 页到 song RAM, 不自动播放
//=============================================================================
`timescale 1ns/1ps

module flash_song (
    input  wire         clk,
    input  wire         rst_n,

    //---- Flash 引脚 ----
    output wire         cs,
    output wire         sclk,
    output wire         mosi,
    input  wire         miso,

    //---- 控制 ----
    input  wire         save_req,
    input  wire [11:0]  cur_len,
    input  wire [3:0]   slot_sel,
    input  wire         delete_req,
    output reg          delete_busy,
    output reg          delete_done,
    output reg          save_busy,
    output reg          save_done,
    output reg          save_err,
    input  wire         load_req,
    output reg          load_busy,
    output reg          load_done,
    output reg          load_active,

    //---- 曲名 (16 字节) ----
    input  wire [127:0] save_name,
    input  wire         name_req,
    input  wire [3:0]   name_slot,
    output reg          name_done,
    output reg  [127:0] name_data,
    output reg          name_valid,

    //---- 写 song RAM（加载时） ----
    output reg  [11:0]  wr_addr,
    output reg  [31:0]  wr_data,
    output reg          wr_en,
    output reg  [11:0]  song_len,
    output reg  [15:0]  lib_mask,
    output reg  [3:0]   lib_current,

    //---- 读 song RAM（保存时） ----
    output reg  [11:0]  ext_addr,
    input  wire [31:0]  ext_data,
    output reg          ext_en
);

    localparam [5:0] S_BOOT     = 6'd0,
                     S_IDLE     = 5'd1,
                     S_LD_META  = 5'd2,
                     S_LD_METAW = 5'd3,
                     S_LD_PG    = 5'd4,
                     S_LD_PGW   = 5'd5,
                     S_LD_WR    = 5'd6,
                     S_LD_DONE  = 5'd7,
                     S_SV_ERW   = 5'd8,
                     S_SV_ER    = 5'd9,
                     S_SV_ERW2  = 5'd10,
                     S_SV_ERWT  = 5'd11,
                     S_SV_FILL  = 5'd12,
                     S_SV_FILLW = 5'd13,
                     S_SV_PGW   = 5'd14,
                     S_SV_PG    = 5'd15,
                     S_SV_PGW2  = 5'd16,
                     S_SV_PGWT  = 5'd17,
                     S_SV_META  = 5'd18,
                     S_SV_METAW = 5'd19,
                     S_SV_METAP = 5'd20,
                     S_SV_METAWT= 5'd21,
                     S_SV_DONE  = 5'd22,
                     S_SV_FILLW2= 5'd23,
                     S_SV_VERIFY= 5'd24,
                     S_SV_VERIFYW=5'd25,
                     S_SV_VPG   = 5'd26,
                     S_SV_VPGW  = 5'd27,
                     S_SV_VSUM  = 5'd28,
                     S_LD_CHK   = 5'd29,
                     S_SV_VCHK  = 5'd30,
                     S_SCAN     = 6'd31,
                     S_INFO     = 6'd32;

    reg [5:0]  st;
    reg [23:0] wait_cnt;
    reg [3:0]  sec_idx;
    reg [3:0]  op_slot;
    reg        deleting;
    reg [3:0]  scan_slot;
    reg [3:0]  last_valid;
    reg [1:0]  scan_phase;
    reg        scan_any;
    wire [23:0] scan_addr = {8'd0, scan_slot, 16'd0};
    reg [5:0]  page_idx;
    reg [6:0]  fill_i;
    reg [5:0]  wr_i;
    reg [11:0] len_lat;
    reg        save_pending;
    reg [5:0]  vpage_idx;
    reg [5:0]  v_i;
    reg [31:0] save_sum;
    reg [31:0] verify_sum;
    reg [31:0] load_sum;
    reg [31:0] csum_lat;

    // 256 字节页缓冲
    reg [7:0]  pbuf [0:255];

    // xact 接口
    reg         xact_start;
    reg [31:0]  xact_hdr;
    reg [2:0]   xact_hdr_len;
    reg [15:0]  xact_nbytes;
    reg         xact_mode;
    wire        xact_done;
    wire        xact_busy;
    wire [7:0]  buf_raddr;
    wire [7:0]  buf_rdata;
    wire        buf_we;
    wire [7:0]  buf_waddr;
    wire [7:0]  buf_wdata;

    flash_xact u_xact (
        .clk       (clk),
        .rst_n     (rst_n),
        .start     (xact_start),
        .hdr       (xact_hdr),
        .hdr_len   (xact_hdr_len),
        .nbytes    (xact_nbytes),
        .mode      (xact_mode),
        .buf_raddr (buf_raddr),
        .buf_rdata (buf_rdata),
        .buf_we    (buf_we),
        .buf_waddr (buf_waddr),
        .buf_wdata (buf_wdata),
        .cs        (cs),
        .sclk      (sclk),
        .mosi      (mosi),
        .miso      (miso),
        .busy      (xact_busy),
        .done      (xact_done)
    );

    // 页缓冲读口（写口合并到主状态机，避免多驱动）
    assign buf_rdata = pbuf[buf_raddr];

    wire [11:0] ev_base = {page_idx, 6'd0};   // page*64
    wire [23:0] slot_base = {8'd0, op_slot, 16'd0};   // 槽位*64KB
    wire [23:0] page_addr = slot_base + 24'h001000 + {10'd0, page_idx, 8'd0};
    wire [23:0] v_addr    = slot_base + 24'h001000 + {10'd0, vpage_idx, 8'd0};
    wire [23:0] erase_addr= slot_base + {8'd0, sec_idx, 12'h000};
    wire [31:0] cur_word  = {pbuf[{wr_i,2'b11}], pbuf[{wr_i,2'b10}],
                             pbuf[{wr_i,2'b01}], pbuf[{wr_i,2'b00}]};
    wire [11:0] scan_len  = {pbuf[5][3:0], pbuf[4]};
    wire        scan_valid= (pbuf[0]==8'h41) && (pbuf[1]==8'h43) &&
                            (pbuf[2]==8'h47) && (pbuf[3]==8'h37) &&
                            (scan_len <= 12'd4095);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st          <= S_BOOT;
            wait_cnt    <= 24'd1_000_000;   // 20ms
            sec_idx     <= 4'd0;
            op_slot     <= 4'd0;
            deleting    <= 1'b0;
            scan_slot   <= 4'd0;
            last_valid  <= 4'd0;
            scan_phase  <= 2'd0;
            scan_any    <= 1'b0;
            lib_mask    <= 16'd0;
            lib_current <= 4'd0;
            page_idx    <= 6'd0;
            fill_i      <= 6'd0;
            wr_i        <= 6'd0;
            len_lat     <= 12'd0;
            save_busy   <= 1'b0;
            save_done   <= 1'b0;
            save_err    <= 1'b0;
            delete_busy <= 1'b0;
            delete_done <= 1'b0;
            load_busy   <= 1'b1;
            load_done   <= 1'b0;
            load_active <= 1'b1;
            wr_addr     <= 12'd0;
            wr_data     <= 32'd0;
            wr_en       <= 1'b0;
            song_len    <= 12'd0;
            ext_addr    <= 12'd0;
            ext_en      <= 1'b0;
            vpage_idx   <= 6'd0;
            v_i         <= 6'd0;
            save_sum    <= 32'd0;
            verify_sum  <= 32'd0;
            load_sum    <= 32'd0;
            csum_lat    <= 32'd0;
            xact_start  <= 1'b0;
            xact_hdr    <= 32'd0;
            xact_hdr_len<= 3'd1;
            xact_nbytes <= 16'd0;
            xact_mode   <= 1'b0;
            name_done   <= 1'b0;
            name_data   <= 128'd0;
            name_valid  <= 1'b0;
        end else begin
            xact_start <= 1'b0;
            wr_en      <= 1'b0;
            save_done  <= 1'b0;
            load_done  <= 1'b0;
            delete_done<= 1'b0;
            name_done  <= 1'b0;
            ext_en     <= 1'b0;
            if (save_req) save_pending <= 1'b1;
            if (buf_we) pbuf[buf_waddr] <= buf_wdata;

            case (st)
            //=================================================================
            S_BOOT: begin
                if (wait_cnt == 24'd0) begin
                    lib_mask   <= 16'd0;
                    scan_slot  <= 4'd0;
                    last_valid <= 4'd0;
                    scan_phase <= 2'd0;
                    scan_any   <= 1'b0;
                    st         <= S_SCAN;
                end else wait_cnt <= wait_cnt - 1'b1;
            end
            //=================================================================
            S_SCAN: begin
                case (scan_phase)
                2'd0: begin
                    xact_hdr    <= {8'h03, scan_addr};
                    xact_hdr_len<= 3'd4;
                    xact_nbytes <= 16'd32;
                    xact_mode   <= 1'b1;
                    xact_start  <= 1'b1;
                    scan_phase  <= 2'd1;
                end
                2'd1: begin
                    if (xact_done) begin
                        if (scan_valid) begin
                            lib_mask[scan_slot] <= 1'b1;
                            last_valid          <= scan_slot;
                            scan_any            <= 1'b1;
                        end
                        if (scan_slot == 4'd15) begin
                            op_slot <= scan_valid ? scan_slot :
                                       (scan_any ? last_valid : 4'd0);
                            st      <= S_LD_META;
                        end else begin
                            scan_slot  <= scan_slot + 1'b1;
                            scan_phase <= 2'd0;
                        end
                    end
                end
                default: scan_phase <= 2'd0;
                endcase
            end
            //=================================================================
            S_IDLE: begin
                load_active <= 1'b0;
                if (save_pending) begin
                    save_pending <= 1'b0;
                    save_busy <= 1'b1;
                    save_err  <= 1'b0;
                    op_slot   <= slot_sel;
                    deleting  <= 1'b0;
                    sec_idx   <= 4'd0;
                    page_idx  <= 6'd0;
                    fill_i    <= 7'd0;
                    len_lat   <= (cur_len > 12'd4095) ? 12'd4095 : cur_len;
                    save_sum  <= 32'd0;
                    verify_sum<= 32'd0;
                    vpage_idx <= 6'd0;
                    v_i       <= 6'd0;
                    st        <= S_SV_ERW;
                end else if (save_req) begin
                    save_busy <= 1'b1;
                    save_err  <= 1'b0;
                    op_slot   <= slot_sel;
                    deleting  <= 1'b0;
                    sec_idx   <= 4'd0;
                    page_idx  <= 6'd0;
                    fill_i    <= 7'd0;
                    len_lat   <= (cur_len > 12'd4095) ? 12'd4095 : cur_len;
                    save_sum  <= 32'd0;
                    verify_sum<= 32'd0;
                    vpage_idx <= 6'd0;
                    v_i       <= 6'd0;
                    st        <= S_SV_ERW;
                end else if (delete_req) begin
                    op_slot     <= slot_sel;
                    deleting    <= 1'b1;
                    delete_busy <= 1'b1;
                    save_err    <= 1'b0;
                    sec_idx     <= 4'd0;
                    st          <= S_SV_ERW;
                end else if (load_req) begin
                    load_busy   <= 1'b1;
                    load_active <= 1'b1;
                    load_sum    <= 32'd0;
                    csum_lat    <= 32'd0;
                    op_slot     <= slot_sel;
                    st          <= S_LD_META;
                end else if (name_req) begin
                    xact_hdr    <= {8'h03, 4'd0, name_slot, 16'd0};
                    xact_hdr_len<= 3'd4;
                    xact_nbytes <= 16'd32;
                    xact_mode   <= 1'b1;
                    xact_start  <= 1'b1;
                    st          <= S_INFO;
                end
            end
            //=================================================================
            S_INFO: begin
                if (xact_done) begin
                    name_data  <= {pbuf[27], pbuf[26], pbuf[25], pbuf[24],
                                   pbuf[23], pbuf[22], pbuf[21], pbuf[20],
                                   pbuf[19], pbuf[18], pbuf[17], pbuf[16],
                                   pbuf[15], pbuf[14], pbuf[13], pbuf[12]};
                    name_valid <= (pbuf[0]==8'h41 && pbuf[1]==8'h43 &&
                                   pbuf[2]==8'h47 && pbuf[3]==8'h37);
                    name_done  <= 1'b1;
                    st         <= S_IDLE;
                end
            end
            //=================================================================
            S_LD_META: begin
                xact_hdr    <= {8'h03, slot_base};
                xact_hdr_len<= 3'd4;
                xact_nbytes <= 16'd32;
                xact_mode   <= 1'b1;
                xact_start  <= 1'b1;
                st          <= S_LD_METAW;
            end
            //=================================================================
            S_LD_METAW: begin
                if (xact_done) begin
                    if (pbuf[0]==8'h41 && pbuf[1]==8'h43 && pbuf[2]==8'h47 && pbuf[3]==8'h37) begin
                        len_lat <= {pbuf[5][3:0], pbuf[4]};
                        csum_lat<= {pbuf[9], pbuf[8], pbuf[7], pbuf[6]};
                        page_idx<= 6'd0;
                        st      <= S_LD_PG;
                    end else begin
                        song_len   <= 12'd0;
                        load_active<= 1'b0;
                        load_busy  <= 1'b0;
                        load_done  <= 1'b1;
                        st         <= S_IDLE;
                    end
                end
            end
            //=================================================================
            S_LD_PG: begin
                xact_hdr    <= {8'h03, page_addr};
                xact_hdr_len<= 3'd4;
                xact_nbytes <= 16'd256;
                xact_mode   <= 1'b1;
                xact_start  <= 1'b1;
                st          <= S_LD_PGW;
            end
            //=================================================================
            S_LD_PGW: begin
                if (xact_done) begin
                    wr_i <= 6'd0;
                    st   <= S_LD_WR;
                end
            end
            //=================================================================
            S_LD_WR: begin
                if (({page_idx, 6'd0} + wr_i) < len_lat) begin
                    wr_en   <= 1'b1;
                    wr_addr <= {page_idx, 6'd0} + wr_i;
                    wr_data <= cur_word;
                    load_sum<= load_sum + cur_word;
                end
                if (wr_i == 6'd63) begin
                    if (page_idx == 6'd63) begin
                        st <= S_LD_CHK;
                    end else begin
                        page_idx <= page_idx + 1'b1;
                        st       <= S_LD_PG;
                    end
                end else begin
                    wr_i <= wr_i + 1'b1;
                end
            end
            //=================================================================
            S_LD_CHK: begin
                if (load_sum == csum_lat) begin
                    song_len    <= len_lat;
                    lib_current <= op_slot;
                end else begin
                    song_len <= 12'd0;      // 校验失败，拒绝播放
                end
                load_active <= 1'b0;
                load_busy   <= 1'b0;
                load_done   <= 1'b1;
                st          <= S_IDLE;
            end
            //=================================================================
            // 保存: 擦除扇区 0~4（元数据 + 16KB 事件）
            S_SV_ERW: begin
                xact_hdr    <= 32'h06000000;
                xact_hdr_len<= 3'd1;
                xact_nbytes <= 16'd0;
                xact_mode   <= 1'b0;
                xact_start  <= 1'b1;
                st          <= S_SV_ER;
            end
            //=================================================================
            S_SV_ER: begin
                if (xact_done) begin
                    xact_hdr    <= {8'h20, erase_addr};
                    xact_hdr_len<= 3'd4;
                    xact_nbytes <= 16'd0;
                    xact_mode   <= 1'b0;
                    xact_start  <= 1'b1;
                    st          <= S_SV_ERW2;
                end
            end
            //=================================================================
            S_SV_ERW2: begin
                if (xact_done) begin
                    wait_cnt <= 24'd5_000_000;   // 100ms
                    st       <= S_SV_ERWT;
                end
            end
            //=================================================================
            S_SV_ERWT: begin
                if (wait_cnt == 24'd0) begin
                    if (sec_idx == 4'd4) begin
                        if (deleting) begin
                            st <= S_SV_DONE;
                        end else begin
                            page_idx <= 6'd0;
                            st       <= S_SV_FILL;
                        end
                    end else begin
                        sec_idx <= sec_idx + 1'b1;
                        st      <= S_SV_ERW;
                    end
                end else wait_cnt <= wait_cnt - 1'b1;
            end
            //=================================================================
            S_SV_FILL: begin
                if (fill_i == 7'd64) begin
                    st <= S_SV_PGW;
                end else if ((ev_base + fill_i[5:0]) < len_lat) begin
                    ext_addr <= ev_base + fill_i[5:0];
                    ext_en   <= 1'b1;
                    st       <= S_SV_FILLW;
                end else begin
                    pbuf[{fill_i[5:0],2'b11}] <= 8'd0;
                    pbuf[{fill_i[5:0],2'b10}] <= 8'd0;
                    pbuf[{fill_i[5:0],2'b01}] <= 8'd0;
                    pbuf[{fill_i[5:0],2'b00}] <= 8'd0;
                    fill_i <= fill_i + 1'b1;
                end
            end
            //=================================================================
            S_SV_FILLW: begin
                // 这里再等一拍，让 song_engine 的 data_r 更新
                st <= S_SV_FILLW2;
            end
            //=================================================================
            S_SV_FILLW2: begin
                pbuf[{fill_i[5:0],2'b11}] <= ext_data[31:24];
                pbuf[{fill_i[5:0],2'b10}] <= ext_data[23:16];
                pbuf[{fill_i[5:0],2'b01}] <= ext_data[15:8];
                pbuf[{fill_i[5:0],2'b00}] <= ext_data[7:0];
                save_sum <= save_sum + ext_data;
                fill_i <= fill_i + 1'b1;
                st     <= S_SV_FILL;
            end
            //=================================================================
            S_SV_PGW: begin
                xact_hdr    <= 32'h06000000;
                xact_hdr_len<= 3'd1;
                xact_nbytes <= 16'd0;
                xact_mode   <= 1'b0;
                xact_start  <= 1'b1;
                st          <= S_SV_PG;
            end
            //=================================================================
            S_SV_PG: begin
                if (xact_done) begin
                    xact_hdr    <= {8'h02, page_addr};
                    xact_hdr_len<= 3'd4;
                    xact_nbytes <= 16'd256;
                    xact_mode   <= 1'b0;
                    xact_start  <= 1'b1;
                    st          <= S_SV_PGW2;
                end
            end
            //=================================================================
            S_SV_PGW2: begin
                if (xact_done) begin
                    wait_cnt <= 24'd250_000;   // 5ms
                    st       <= S_SV_PGWT;
                end
            end
            //=================================================================
            S_SV_PGWT: begin
                if (wait_cnt == 24'd0) begin
                    if (page_idx == 6'd63) begin
                        st <= S_SV_META;
                    end else begin
                        page_idx <= page_idx + 1'b1;
                        fill_i   <= 7'd0;
                        st       <= S_SV_FILL;
                    end
                end else wait_cnt <= wait_cnt - 1'b1;
            end
            //=================================================================
            S_SV_META: begin
                pbuf[0] <= 8'h41; pbuf[1] <= 8'h43;
                pbuf[2] <= 8'h47; pbuf[3] <= 8'h37;
                pbuf[4] <= len_lat[7:0];
                pbuf[5] <= {4'd0, len_lat[11:8]};
                pbuf[6] <= save_sum[7:0];
                pbuf[7] <= save_sum[15:8];
                pbuf[8] <= save_sum[23:16];
                pbuf[9] <= save_sum[31:24];
                pbuf[10]<= 8'd0; pbuf[11] <= 8'd0;
                pbuf[12]<= save_name[7:0];
                pbuf[13]<= save_name[15:8];
                pbuf[14]<= save_name[23:16];
                pbuf[15]<= save_name[31:24];
                pbuf[16]<= save_name[39:32];
                pbuf[17]<= save_name[47:40];
                pbuf[18]<= save_name[55:48];
                pbuf[19]<= save_name[63:56];
                pbuf[20]<= save_name[71:64];
                pbuf[21]<= save_name[79:72];
                pbuf[22]<= save_name[87:80];
                pbuf[23]<= save_name[95:88];
                pbuf[24]<= save_name[103:96];
                pbuf[25]<= save_name[111:104];
                pbuf[26]<= save_name[119:112];
                pbuf[27]<= save_name[127:120];
                pbuf[28]<= 8'd0; pbuf[29]<=8'd0; pbuf[30]<=8'd0; pbuf[31]<=8'd0;
                st <= S_SV_METAW;
            end
            //=================================================================
            S_SV_METAW: begin
                xact_hdr    <= 32'h06000000;
                xact_hdr_len<= 3'd1;
                xact_nbytes <= 16'd0;
                xact_mode   <= 1'b0;
                xact_start  <= 1'b1;
                st          <= S_SV_METAP;
            end
            //=================================================================
            S_SV_METAP: begin
                if (xact_done) begin
                    xact_hdr    <= {8'h02, slot_base};
                    xact_hdr_len<= 3'd4;
                    xact_nbytes <= 16'd32;
                    xact_mode   <= 1'b0;
                    xact_start  <= 1'b1;
                    st          <= S_SV_METAWT;
                end
            end
            //=================================================================
            S_SV_METAWT: begin
                if (xact_done) begin
                    // 页编程后要等内部写完成，不能立刻读回
                    wait_cnt <= 24'd250_000;   // 5ms
                    st       <= S_SV_VERIFYW;
                end
            end
            //=================================================================
            S_SV_VERIFYW: begin
                if (wait_cnt == 24'd0) begin
                    // 读回元数据，校验 magic + 长度
                    xact_hdr    <= {8'h03, slot_base};
                    xact_hdr_len<= 3'd4;
                    xact_nbytes <= 16'd32;
                    xact_mode   <= 1'b1;
                    xact_start  <= 1'b1;
                    st          <= S_SV_VERIFY;
                end else begin
                    wait_cnt <= wait_cnt - 1'b1;
                end
            end
            //=================================================================
            S_SV_VERIFY: begin
                if (xact_done) begin
                    if ((pbuf[0] != 8'h41) || (pbuf[1] != 8'h43) ||
                        (pbuf[2] != 8'h47) || (pbuf[3] != 8'h37) ||
                        (pbuf[4] != len_lat[7:0]) ||
                        (pbuf[5] != {4'd0, len_lat[11:8]}) ||
                        (pbuf[6] != save_sum[7:0]) ||
                        (pbuf[7] != save_sum[15:8]) ||
                        (pbuf[8] != save_sum[23:16]) ||
                        (pbuf[9] != save_sum[31:24])) begin
                        save_err <= 1'b1;
                        st       <= S_SV_DONE;
                    end else begin
                        vpage_idx  <= 6'd0;
                        verify_sum <= 32'd0;
                        st         <= S_SV_VPG;
                    end
                end
            end
            //=================================================================
            S_SV_VPG: begin
                xact_hdr    <= {8'h03, v_addr};
                xact_hdr_len<= 3'd4;
                xact_nbytes <= 16'd256;
                xact_mode   <= 1'b1;
                xact_start  <= 1'b1;
                st          <= S_SV_VPGW;
            end
            //=================================================================
            S_SV_VPGW: begin
                if (xact_done) begin
                    v_i <= 6'd0;
                    st  <= S_SV_VSUM;
                end
            end
            //=================================================================
            S_SV_VSUM: begin
                if (({vpage_idx, 6'd0} + v_i) < len_lat) begin
                    verify_sum <= verify_sum +
                        {pbuf[{v_i,2'b11}], pbuf[{v_i,2'b10}],
                         pbuf[{v_i,2'b01}], pbuf[{v_i,2'b00}]};
                end
                if (v_i == 6'd63) begin
                    if (vpage_idx == 6'd63)
                        st <= S_SV_VCHK;
                    else begin
                        vpage_idx <= vpage_idx + 1'b1;
                        st        <= S_SV_VPG;
                    end
                end else begin
                    v_i <= v_i + 1'b1;
                end
            end
            //=================================================================
            S_SV_VCHK: begin
                if (verify_sum != save_sum) save_err <= 1'b1;
                st <= S_SV_DONE;
            end
            //=================================================================
            S_SV_DONE: begin
                if (deleting) begin
                    save_busy   <= 1'b0;
                    delete_busy <= 1'b0;
                    delete_done <= 1'b1;
                    lib_mask[op_slot] <= 1'b0;
                    if (lib_current == op_slot) lib_current <= 4'd0;
                end else begin
                    save_busy <= 1'b0;
                    save_done <= 1'b1;
                    if (!save_err) begin
                        lib_mask[op_slot] <= 1'b1;
                        lib_current       <= op_slot;
                    end
                end
                deleting <= 1'b0;
                st       <= S_IDLE;
            end
            //=================================================================
            default: st <= S_IDLE;
            endcase
        end
    end

endmodule
