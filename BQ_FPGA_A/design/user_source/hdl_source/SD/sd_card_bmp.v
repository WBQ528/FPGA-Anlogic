
module sd_card_bmp #(
    parameter integer USE_FAT16 = 1,
    parameter integer EXTERNAL_SD = 0,
    parameter integer CACHE_IMAGES = USE_FAT16,
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter integer LOAD_TIMEOUT_SEC  = 10,
    parameter [31:0]  SCAN_START_SECTOR = 32'd0,
    parameter [31:0]  SCAN_MAX_SECTOR   = 32'd131071,
    parameter [2:0]   SCAN_TARGET_COUNT = 3'd4
)(
    input                       clk,
    input                       rst,
    input                       key_next,
    input                       key_auto,
    input                       key_period,
    output [1:0]                displayed_image,
    output reg [1:0]            period_mode,
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,
    output reg                  display_valid,
    output      [3:0]           state_code,
    output      [2:0]           debug_found_count,
    output                      debug_auto_play_en,
    output reg                  slide_paused,

    input                       display_commit_ack,
    input                       write_finish_toggle,
    output reg [1:0]            write_buf_idx,
    output reg [1:0]            disp_buf_idx,

    output                      write_req,
    input                       write_req_ack,
    input                       write_ready,
    output                      write_en,
    output [31:0]               write_data,
    output                      SD_nCS,
    output                      SD_DCLK,
    output                      SD_MOSI,
    input                       SD_MISO,
    input ext_init,ext_valid,ext_end,input [7:0] ext_data,
    output ext_req,output [31:0] ext_addr,output ext_reset,
    output [43:0] native_widths,native_heights
);

reg [1:0]        img_idx;              // 当前真正显示中的图片编号
reg              source_started;
wire key_next_press;
wire key_period_press;
reg [2:0] auto_seconds;
wire [2:0] period_seconds = period_mode == 0 ? 3'd1 : period_mode == 1 ? 3'd3 : 3'd5;
assign displayed_image = img_idx;
key_press_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ),.DEBOUNCE_MS(20)) u_key_period(
 .clk(clk),.rst(rst),.button_in(key_period),.press_pulse(key_period_press));

wire             sd_sec_read;
wire [31:0]      sd_sec_read_addr;
wire [7:0]       sd_sec_read_data;
wire             sd_sec_read_data_valid;
wire             sd_sec_read_end;
wire [3:0]       state_code_i;
wire             bmp_data_wr_en;
wire [23:0]      bmp_data;
wire             sd_init_done;
wire             bmp_ready;
wire             scan_done;
wire             scan_found_valid;
wire [31:0]      scan_found_sector;
wire [2:0]       scan_found_total;

reg              scan_start_pulse;
reg              load_start_pulse;
reg [31:0]       load_sector;
reg              scan_kicked;
reg              first_image_committed;
reg              auto_play_en;
reg [31:0]       auto_cnt;
reg [2:0]        img_found_count;
reg [1:0]        load_idx;             // 当前正在写入的图片编号
reg [1:0]        pending_buf_idx;      // 当前正在写入的目标缓冲区
reg [31:0]       img_sector0;
reg [31:0]       img_sector1;
reg [31:0]       img_sector2;
reg [31:0]       img_sector3;
reg              next_req_pending;
reg              load_busy;
reg [3:0] failed_images;
reg [3:0] cached_images;
reg background_load;
reg [1:0] prefetch_index;
reg prefetch_valid;
always @* begin
 prefetch_index=0;prefetch_valid=1;
 if(img_found_count>0 && !cached_images[0] && !failed_images[0])prefetch_index=0;
 else if(img_found_count>1 && !cached_images[1] && !failed_images[1])prefetch_index=1;
 else if(img_found_count>2 && !cached_images[2] && !failed_images[2])prefetch_index=2;
 else if(img_found_count>3 && !cached_images[3] && !failed_images[3])prefetch_index=3;
 else prefetch_valid=0;
end
reg [3:0] error_latched;
reg [1:0] first_candidate;
reg first_candidate_valid;
always @* begin
 first_candidate=0;first_candidate_valid=1;
 if(img_found_count>0 && !failed_images[0])first_candidate=0;
 else if(img_found_count>1 && !failed_images[1])first_candidate=1;
 else if(img_found_count>2 && !failed_images[2])first_candidate=2;
 else if(img_found_count>3 && !failed_images[3])first_candidate=3;
 else first_candidate_valid=0;
end
wire source_failed = USE_FAT16 && load_busy && source_started && bmp_ready && state_code_i>=4'hc;
reg [31:0]       load_timeout_cnt;

localparam integer LOAD_TIMEOUT_CYCLES = CLK_FREQ_HZ * LOAD_TIMEOUT_SEC;

reg              load_abort;
reg              key_auto_sync0;
reg              key_auto_sync1;
reg              key_auto_held;
wire             key_auto_toggle_pulse;

// bmp_ready 先表示“源文件读取/送 FIFO 完成”；真正切显示要等 write_finish_toggle 同步后
reg              source_done_seen;
wire scan_resume;
// Do not race a just-issued load or consume a found event before caching it.
assign scan_resume = scan_kicked && !scan_done && !scan_found_valid &&
    !load_busy && !load_start_pulse && !next_req_pending && !key_next_press &&
    ((img_found_count == 0) || !first_candidate_valid || (first_image_committed && display_commit_ack));
reg              write_done_seen;

// 同步 mem_clk 域的 write_finish_toggle
reg [2:0]        wrfin_tgl_sync;
wire             write_finish_pulse;

wire auto_tick;
// Predecode the slowly changing high bits. The final low byte is nonzero in
// production (100MHz) and tests (1kHz), so the registered high match is settled
// before the terminal count. Low-byte-zero parameters retain the direct path.
reg second_high_match;
always @(posedge clk or posedge rst)
 if(rst)second_high_match<=((CLK_FREQ_HZ-1)>>8)==0;
 else second_high_match<=(auto_cnt[31:8]==((CLK_FREQ_HZ-1)>>8));
wire second_tick = ((CLK_FREQ_HZ-1)%256)==0 ? (auto_cnt==CLK_FREQ_HZ-1) :
 second_high_match && (auto_cnt[7:0]==((CLK_FREQ_HZ-1)%256));
wire [1:0] next_from_current;

assign write_en   = bmp_data_wr_en;
assign write_data = {bmp_data[23:16], bmp_data[15:8], bmp_data[7:0], 8'b0};
assign auto_tick = auto_play_en && !key_auto_toggle_pulse && second_tick && (auto_seconds == period_seconds-1);
assign next_from_current = next_usable(img_idx, img_found_count, failed_images);
assign write_finish_pulse = wrfin_tgl_sync[2] ^ wrfin_tgl_sync[1];
assign state_code = error_latched!=0 ? error_latched : state_code_i;
assign debug_found_count = img_found_count;
assign debug_auto_play_en = auto_play_en;

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (20)
) u_key_next (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_next),
    .press_pulse(key_next_press)
);

key_press_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ),.DEBOUNCE_MS(20)) u_key_auto (
 .clk(clk),.rst(rst),.button_in(key_auto),.press_pulse(key_auto_toggle_pulse));

function [1:0] next_index_limited;
    input [1:0] cur;
    input [2:0] count;
    begin
        case (count)
            3'd0: next_index_limited = 2'd0;
            3'd1: next_index_limited = 2'd0;
            3'd2: next_index_limited = (cur == 2'd1) ? 2'd0 : (cur + 2'd1);
            3'd3: next_index_limited = (cur == 2'd2) ? 2'd0 : (cur + 2'd1);
            default: next_index_limited = (cur == 2'd3) ? 2'd0 : (cur + 2'd1);
        endcase
    end
endfunction

function [1:0] next_usable;
 input [1:0] current_image;
 input [2:0] count;
 input [3:0] failed;
 reg [3:0] usable;
 begin
  // Four parallel eligibility bits plus cyclic priority. The previous three
  // cascaded variable-count increments crossed nine logic levels at 100MHz.
  usable={count>3,count>2,count>1,count>0} & ~failed;
  case(current_image)
   0:next_usable=usable[1]?1:usable[2]?2:usable[3]?3:0;
   1:next_usable=usable[2]?2:usable[3]?3:usable[0]?0:1;
   2:next_usable=usable[3]?3:usable[0]?0:usable[1]?1:2;
   default:next_usable=usable[0]?0:usable[1]?1:usable[2]?2:3;
  endcase
 end
endfunction

function [31:0] sector_lut;
    input [1:0] idx;
    begin
        case (idx)
            2'd0: sector_lut = img_sector0;
            2'd1: sector_lut = img_sector1;
            2'd2: sector_lut = img_sector2;
            2'd3: sector_lut = img_sector3;
            default: sector_lut = img_sector0;
        endcase
    end
endfunction

function [1:0] next_buf_lut;
    input [1:0] cur_disp_buf;
    input       valid_now;
    begin
        if (!valid_now)
            next_buf_lut = 2'd0;                 // 首图固定写 buffer0
        else if (cur_disp_buf == 2'd0)
            next_buf_lut = 2'd1;
        else
            next_buf_lut = 2'd0;
    end
endfunction

always @(posedge clk or posedge rst) begin
    if (rst) begin
        wrfin_tgl_sync        <= 3'b000;
        scan_start_pulse      <= 1'b0;
        load_start_pulse      <= 1'b0;
        load_sector           <= 32'd0;
        scan_kicked           <= 1'b0;
        first_image_committed <= 1'b0;
        auto_play_en          <= 1'b0;
        slide_paused <= 0;
        auto_cnt              <= 32'd0;
        auto_seconds <= 0;
        period_mode <= 1;
        img_found_count       <= 3'd0;
        img_idx               <= 2'd0;
        load_idx              <= 2'd0;
        pending_buf_idx       <= 2'd0;
        write_buf_idx         <= 2'd0;
        disp_buf_idx          <= 2'd0;
        img_sector0           <= 32'd0;
        img_sector1           <= 32'd0;
        img_sector2           <= 32'd0;
        img_sector3           <= 32'd0;
        next_req_pending      <= 1'b0;
        load_busy             <= 1'b0;
        failed_images<=0;error_latched<=0;cached_images<=0;background_load<=0;
        load_timeout_cnt      <= 32'd0;
        load_abort            <= 1'b0;
        source_done_seen      <= 1'b0;
        source_started       <= 1'b0;
        write_done_seen       <= 1'b0;
        display_valid         <= 1'b0;
    end else begin
        wrfin_tgl_sync   <= {wrfin_tgl_sync[1:0], write_finish_toggle};
        scan_start_pulse <= 1'b0;
        load_start_pulse <= 1'b0;
        load_abort       <= 1'b0;

        if (!sd_init_done) begin
            scan_kicked           <= 1'b0;
            first_image_committed <= 1'b0;
            auto_play_en          <= 1'b0;
        slide_paused <= 0;
            auto_cnt              <= 32'd0;
            img_found_count       <= 3'd0;

            load_idx              <= 2'd0;
            pending_buf_idx       <= 2'd0;
            write_buf_idx         <= 2'd0;

            img_sector0           <= 32'd0;
            img_sector1           <= 32'd0;
            img_sector2           <= 32'd0;
            img_sector3           <= 32'd0;
            next_req_pending      <= 1'b0;
            load_busy             <= 1'b0;
            load_timeout_cnt      <= 32'd0;
            load_abort            <= 1'b0;
            source_done_seen      <= 1'b0;
            source_started       <= 1'b0;
            write_done_seen       <= 1'b0;

            auto_seconds<=0;failed_images<=0;cached_images<=0;background_load<=0;
            if(CACHE_IMAGES)display_valid<=0;
        end else begin
            // 扫描阶段缓存前 4 张图的起始 sector
            if (scan_found_valid) begin
                case (img_found_count)
                    3'd0: img_sector0 <= scan_found_sector;
                    3'd1: img_sector1 <= scan_found_sector;
                    3'd2: img_sector2 <= scan_found_sector;
                    3'd3: img_sector3 <= scan_found_sector;
                    default: ;
                endcase

                if (img_found_count < 3'd4)
                    img_found_count <= img_found_count + 3'd1;
            end

            // 记住 bmp_read 已经把源图送完 FIFO，但还不能切显示，得等整帧写完
            if (load_busy && !bmp_ready) source_started <= 1'b1;
            if (load_busy && source_started && bmp_ready)
                source_done_seen <= 1'b1;

            // 记住写帧完成脉冲，避免“先写完后源结束”导致脉冲丢失而卡死
            if (load_busy && write_finish_pulse)
                write_done_seen <= 1'b1;

            // 只有“源图送完 + 整帧写完”都满足，才提交新图并切换显示缓冲区
            if (load_busy && source_done_seen && write_done_seen && !source_failed) begin
                load_busy             <= 1'b0;
                load_timeout_cnt      <= 32'd0;
                source_done_seen      <= 1'b0;
                source_started       <= 1'b0;
                write_done_seen       <= 1'b0;
                cached_images[load_idx] <= 1'b1;
                if(!background_load)begin
                 disp_buf_idx<=pending_buf_idx;img_idx<=load_idx;
                 display_valid<=1'b1;first_image_committed<=1'b1;
                end
                background_load<=0;
                error_latched<=0;
            end else if(source_failed)begin
                load_busy<=0;source_done_seen<=0;source_started<=0;write_done_seen<=0;
                failed_images[load_idx]<=1;error_latched<=state_code_i;next_req_pending<=0;background_load<=0;
                if(state_code_i==4'he)load_abort<=1;
            end else if (load_busy) begin
                if (load_timeout_cnt >= LOAD_TIMEOUT_CYCLES - 1) begin
                    // Abort a genuinely stalled or damaged image without
                    // rejecting a valid frame from a slower TF card.
                    load_busy             <= 1'b0;
                    load_timeout_cnt      <= 32'd0;
                    source_done_seen      <= 1'b0;
                    source_started       <= 1'b0;
                    write_done_seen       <= 1'b0;
                    load_abort            <= 1'b1;
                    error_latched<=4'he;
                end else begin
                    load_timeout_cnt <= load_timeout_cnt + 32'd1;
                end
            end else begin
                load_timeout_cnt <= 32'd0;
            end

            // 上电后自动发起一次“扫描前 4 张 BMP”
            if (!scan_kicked && bmp_ready) begin
                scan_start_pulse      <= 1'b1;
                scan_kicked           <= 1'b1;
                first_image_committed <= 1'b0;
                auto_play_en          <= 1'b0;
        slide_paused <= 0;
                auto_cnt              <= 32'd0;
                img_found_count       <= 3'd0;

                load_idx              <= 2'd0;
                pending_buf_idx       <= 2'd0;
                write_buf_idx         <= 2'd0;

                next_req_pending      <= 1'b0;

                load_busy             <= 1'b0;
                source_done_seen      <= 1'b0;
                source_started       <= 1'b0;
                write_done_seen       <= 1'b0;
                failed_images<=0;auto_seconds<=0;cached_images<=0;background_load<=0;
            end else begin
                // 忙的时候也只记 1 次“下一张”请求，不会累积成连跳两张
                if (key_next_press && (img_found_count > 3'd0))
                    next_req_pending <= 1'b1;

                // 自动播放开/关
                // Let the user arm/disarm auto play at any time. Playback itself
                // remains gated below until scanning has found enough images.
                // R2-01: manual selection explicitly leaves both auto and pause.
                // KEY2 wins if both keys arrive together; reset the entire dwell.
                if (key_next_press) begin
                    auto_play_en <= 1'b0;
                    slide_paused <= 1'b0;
                end else if (key_auto_toggle_pulse) begin
                    auto_play_en <= ~auto_play_en;
                    slide_paused <= auto_play_en;
                end

                // Dwell starts after the displayed frame is acknowledged.
                if (key_period_press) period_mode <= period_mode == 2 ? 0 : period_mode+1'b1;
                // Separate seconds counter avoids a large variable comparator.
                if (!key_next_press && !key_auto_toggle_pulse && !key_period_press && scan_done && auto_play_en && display_valid && !load_busy && display_commit_ack && first_image_committed && (img_found_count > 3'd1)) begin
                    if (second_tick) begin
                        auto_cnt <= 0;
                        auto_seconds <= auto_tick ? 0 : auto_seconds+1'b1;
                    end
                    else
                        auto_cnt <= auto_cnt + 32'd1;
                end else if(key_period_press || key_next_press || !display_valid || !display_commit_ack ||
                             !(slide_paused || key_auto_toggle_pulse))begin
                    auto_cnt <= 32'd0;
                    auto_seconds <= 0;
                end

                // 首图自动加载到 buffer0
                if (!source_failed && !first_image_committed && bmp_ready && !load_busy && display_commit_ack && first_candidate_valid) begin
                    load_idx         <= first_candidate;
                    load_sector      <= sector_lut(first_candidate);
                    pending_buf_idx  <= CACHE_IMAGES ? first_candidate : next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx    <= CACHE_IMAGES ? first_candidate : next_buf_lut(disp_buf_idx, display_valid);
                    background_load <= 0;
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    source_started       <= 1'b0;
                    write_done_seen  <= 1'b0;
                    next_req_pending <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
                // Immutable four-slot cache: only valid, completed frames can be selected.
                else if (bmp_ready && display_valid && !load_busy && display_commit_ack &&
                    (next_req_pending || (!key_next_press && !key_auto_toggle_pulse && !key_period_press &&
                     scan_done && auto_play_en && auto_tick && img_found_count>1))) begin
                    next_req_pending<=0;auto_cnt<=0;
                    if(CACHE_IMAGES && cached_images[next_from_current])begin
                        disp_buf_idx<=next_from_current;img_idx<=next_from_current;
                    end else begin
                        load_idx<=next_from_current;load_sector<=sector_lut(next_from_current);
                        pending_buf_idx<=CACHE_IMAGES ? next_from_current : next_buf_lut(disp_buf_idx,display_valid);
                        write_buf_idx<=CACHE_IMAGES ? next_from_current : next_buf_lut(disp_buf_idx,display_valid);
                        load_start_pulse<=1;load_busy<=1;background_load<=0;
                        source_done_seen<=0;source_started<=0;write_done_seen<=0;
                    end
                end
                // Catalog has priority; prefetch never changes the displayed image or tone.
                else if(CACHE_IMAGES && scan_done && display_valid && bmp_ready && !load_busy &&
                        display_commit_ack && !key_next_press && prefetch_valid)begin
                    load_idx<=prefetch_index;load_sector<=sector_lut(prefetch_index);
                    pending_buf_idx<=prefetch_index;write_buf_idx<=prefetch_index;
                    load_start_pulse<=1;load_busy<=1;background_load<=1;
                    source_done_seen<=0;source_started<=0;write_done_seen<=0;
                end
                // An already cached manual target need not wait for unrelated prefetch.
                if(CACHE_IMAGES && background_load && display_valid && display_commit_ack &&
                   next_req_pending && cached_images[next_from_current])begin
                    disp_buf_idx<=next_from_current;img_idx<=next_from_current;
                    next_req_pending<=0;auto_cnt<=0;
                end

            end
        end
    end
end

generate if(USE_FAT16) begin: fat_backend
fat16_bmp_read #(.READ_TIMEOUT(CLK_FREQ_HZ*2)) bmp_read_m0(
    .native_widths(native_widths),.native_heights(native_heights),
    .output_ready(write_ready),
    .clk                    (clk),
    .rst                    (rst),
    .ready                  (bmp_ready),

    .scan_start             (scan_start_pulse),
    .scan_resume            (scan_resume),
    .scan_start_sector      (SCAN_START_SECTOR),
    .scan_max_sector        (SCAN_MAX_SECTOR),
    .scan_target_count      (SCAN_TARGET_COUNT),
    .scan_done              (scan_done),
    .scan_found_valid       (scan_found_valid),
    .scan_found_sector      (scan_found_sector),
    .scan_found_total       (scan_found_total),

    .load_start             (load_start_pulse),
    .load_abort             (load_abort),
    .load_sector            (load_sector),

    .sd_init_done           (sd_init_done),
    .state_code             (state_code_i),
    .bmp_width              (bmp_width),
    .bmp_height             (bmp_height),
    .write_req              (write_req),
    .write_req_ack          (write_req_ack),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .bmp_data_wr_en         (bmp_data_wr_en),
    .bmp_data               (bmp_data)
);
end else begin: raw_backend
assign native_widths={4{11'd640}};
assign native_heights={4{11'd480}};
bmp_read bmp_read_m0(
    .clk                    (clk),
    .rst                    (rst),
    .ready                  (bmp_ready),

    .scan_start             (scan_start_pulse),
    .scan_resume            (scan_resume),
    .scan_start_sector      (SCAN_START_SECTOR),
    .scan_max_sector        (SCAN_MAX_SECTOR),
    .scan_target_count      (SCAN_TARGET_COUNT),
    .scan_done              (scan_done),
    .scan_found_valid       (scan_found_valid),
    .scan_found_sector      (scan_found_sector),
    .scan_found_total       (scan_found_total),

    .load_start             (load_start_pulse),
    .load_abort             (load_abort),
    .load_sector            (load_sector),

    .sd_init_done           (sd_init_done),
    .state_code             (state_code_i),
    .bmp_width              (bmp_width),
    .bmp_height             (bmp_height),
    .write_req              (write_req),
    .write_req_ack          (write_req_ack),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .bmp_data_wr_en         (bmp_data_wr_en),
    .bmp_data               (bmp_data)
);
end endgenerate

wire legacy_init,legacy_valid,legacy_end;
wire [7:0] legacy_data;
assign ext_req=sd_sec_read;
assign ext_addr=sd_sec_read_addr;
assign ext_reset=load_abort;
assign sd_init_done=EXTERNAL_SD ? ext_init : legacy_init;
assign sd_sec_read_data=EXTERNAL_SD ? ext_data : legacy_data;
assign sd_sec_read_data_valid=EXTERNAL_SD ? ext_valid : legacy_valid;
assign sd_sec_read_end=EXTERNAL_SD ? ext_end : legacy_end;
sd_card_top sd_card_top_m0(
    .clk                    (clk),
    .rst                    (rst | load_abort | (EXTERNAL_SD!=0)),
    .SD_nCS                 (SD_nCS),
    .SD_DCLK                (SD_DCLK),
    .SD_MOSI                (SD_MOSI),
    .SD_MISO                (SD_MISO),
    .sd_init_done           (legacy_init),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (legacy_data),
    .sd_sec_read_data_valid (legacy_valid),
    .sd_sec_read_end        (legacy_end),
    .sd_sec_write           (1'b0),
    .sd_sec_write_addr      (32'd0),
    .sd_sec_write_data      (8'd0),
    .sd_sec_write_data_req  (),
    .sd_sec_write_end       ()
);

endmodule

module key_press_debounce #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20
)(
    input  wire clk,
    input  wire rst,
    input  wire button_in,    // 默认：松开=1，按下=0
    output reg  press_pulse
);

localparam integer DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;

reg button_sync0;
reg button_sync1;
reg button_stable;
localparam integer COUNT_BITS = DEBOUNCE_CYCLES<=1 ? 1 : $clog2(DEBOUNCE_CYCLES);
reg [COUNT_BITS-1:0] cnt;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        button_sync0  <= 1'b1;
        button_sync1  <= 1'b1;
        button_stable <= 1'b1;
        cnt           <= 32'd0;
        press_pulse   <= 1'b0;
    end else begin
        button_sync0 <= button_in;
        button_sync1 <= button_sync0;
        press_pulse  <= 1'b0;

        if (button_sync1 == button_stable) begin
            cnt <= 32'd0;
        end else begin
            if (cnt >= DEBOUNCE_CYCLES - 1) begin
                if (button_stable && !button_sync1)
                    press_pulse <= 1'b1;
                button_stable <= button_sync1;
                cnt           <= 32'd0;
            end else begin
                cnt <= cnt + 32'd1;
            end
        end
    end
end

endmodule
