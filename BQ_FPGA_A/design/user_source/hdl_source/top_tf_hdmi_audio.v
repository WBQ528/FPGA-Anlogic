

module top #(parameter NATIVE_SD=1, parameter TRANSITIONS=1, parameter PHOTO_LIBRARY=1, parameter PHOTO_MUSIC=1)(
    input                       clk,
    input                       rst_n,
    input                       key1,           // 手动下一张
    input                       key_period,     // KEY3: 1/3/5 second dwell
    input                       key2,           // 自动播放 开/关

	output [5:0]                seg_sel,
	output [7:0]                seg_data,

    // HDMI TMDS
    output                      HDMI_CLK_P,
    output                      HDMI_D2_P,
    output                      HDMI_D1_P,
    output                      HDMI_D0_P,

    // HDMI DDC
    output                      HDMI_DDC_SCL,
    inout                       HDMI_DDC_SDA,

    // TF card SPI
    inout                       sd_ncs,
    output                      sd_dclk,
    inout                       sd_mosi,
    input                       sd_miso,
    input [3:0] switches,
    input sd_dat1,sd_dat2,
    input hmi_rx,output hmi_tx,
    input phy_rxc,input [3:0] phy_rxd,input phy_rxctl,
    output phy_txc,output [3:0] phy_txd,output phy_txctl,output phy_mdc,inout phy_mdio
);

parameter MEM_DATA_BITS = 32;
parameter ADDR_BITS     = 21;
parameter BUSRT_BITS    = 10;
parameter [ADDR_BITS-1:0] FRAME_PIXELS = 21'd614400;   // 1280*960/2 packed RGB565 words
parameter [ADDR_BITS-1:0] BUF0_ADDR = 21'd0;
parameter [ADDR_BITS-1:0] BUF1_ADDR = FRAME_PIXELS;






wire Sdr_init_done;
wire Sdr_init_ref_vld;
wire Sdr_busy;
wire sd_card_clk;
wire ext_mem_clk;
wire ext_mem_clk_sft;
wire video_clk;
wire hdmi_5x_clk;
wire hs;
wire vs;
wire de;
wire [23:0] vout_data_raw;
wire [23:0] vout_data;
wire [23:0] vout_with_status;
wire overlay_hs,overlay_vs,overlay_de,ui_write,ui_loaded;
wire [8:0] ui_address;wire [7:0] ui_data;wire [12:0] movie_total;
wire [10:0] video_status;
wire slide_paused;
wire        display_valid;
wire [3:0]  state_code;
wire [2:0]  debug_found_count;
wire        debug_auto_play_en;
wire [6:0]  seg_state;
wire [6:0]  seg_count;
wire [6:0]  seg_auto;
wire [6:0]  seg_display_valid;
wire        video_read_req;
wire        video_read_req_ack;
wire        video_read_en;
wire [31:0] video_read_data;
wire        sd_card_write_en;
wire [31:0] sd_card_write_data;
wire        sd_card_write_req;
wire        sd_card_write_req_ack;
wire        frame_write_finish;
reg         frame_write_toggle_mem;
wire [1:0]  write_buf_idx;
wire [1:0]  disp_buf_idx;
wire App_rd_en;
wire [ADDR_BITS-1:0] App_rd_addr;
wire Sdr_rd_en;
wire [MEM_DATA_BITS-1:0] Sdr_rd_dout;
wire App_wr_en;
wire [ADDR_BITS-1:0] App_wr_addr;
wire [MEM_DATA_BITS-1:0] App_wr_din;
wire [3:0] App_wr_dm;
wire hs_0;
wire vs_0;
wire de_0;
wire        axis_s_user;
wire        axis_s_valid;
wire        axis_s_last;
wire [23:0] axis_s_data;
wire        axis_s_ready;
wire        edid_trig;
wire        edid_valid;
wire [7:0]  edid_data;
wire [9:0]  tmds_ch0_data;
wire [9:0]  tmds_ch1_data;
wire [9:0]  tmds_ch2_data;
wire [9:0]  tmds_clk_data;
wire sys_pll_lock;
wire video_pll_lock;
wire rst_all;
wire rst_sd, rst_mem, rst_video;
wire display_commit_ack, video_display_valid;
wire [1:0] video_display_buffer;
wire [1:0] requested_image, active_image, period_mode;
wire audio_valid, acr_valid;
wire [23:0] audio_left, audio_right;
wire [19:0] acr_n, acr_cts;
reg movie_mode_boot=0;
reg [2:0] chapter_boot=0;
// The chapter is held through the 2 ms media restart. Decode it only after
// two local sampling stages; do not put board-clock data on the SD header FSM.
(* async_reg="true" *) reg [2:0] chapter_sd_meta=0,chapter_sd=0;
(* async_reg="true" *) reg [2:0] chapter_video_meta=0,chapter_video=0;
always @(posedge sd_card_clk)begin chapter_sd_meta<=chapter_boot;chapter_sd<=chapter_sd_meta;end
always @(posedge video_clk)begin chapter_video_meta<=chapter_boot;chapter_video<=chapter_video_meta;end
(* async_reg="true" *) reg [1:0] mode_video_sync=0,mode_sd_sync=0;
always @(posedge video_clk)begin mode_video_sync<={mode_video_sync[0],movie_mode_boot};end
always @(posedge sd_card_clk)begin mode_sd_sync<={mode_sd_sync[0],movie_mode_boot};end
wire movie_mode=mode_video_sync[1];
wire movie_mode_sd=mode_sd_sync[1];
wire music_mode_sd=PHOTO_MUSIC && NATIVE_SD && !movie_mode_sd;
wire music_mode=PHOTO_MUSIC && NATIVE_SD && !movie_mode;
// Boot straps are static after reset; cross to the PCM/HDMI clock before the
// audio mux, keeping the waveform datapath wholly in the video domain.
reg [1:0] pcm_select_sync;
(* async_reg="true" *) reg [1:0] photo_pause_sync;
always @(posedge video_clk or posedge rst_video)
 if(rst_video)begin pcm_select_sync<=0;photo_pause_sync<=0;end
 else begin
  pcm_select_sync<={pcm_select_sync[0],movie_mode || music_mode};
  // Audio follows the live synchronized control, not the frame-latched OSD.
  // Unmute before the PCM player's third synchronization stage resumes reads.
  photo_pause_sync<={photo_pause_sync[0],slide_paused};
 end
wire media_active=movie_mode_sd || (music_mode_sd && bmp_valid);
// HXA repeats inside the validated file cursor. Track boundaries
// never reset the sample clock/FIFO or the two levels of sector arbitration.
wire [5:0] music_restart=0;
reg [5:0] replay_count=0;
wire replay_press;
wire bmp_valid,bmp_video_valid,bmp_write_req,bmp_write_en;
wire [1:0] bmp_video_bank;
wire [31:0] bmp_write_data;
wire [1:0] bmp_write_bank,bmp_disp_bank;
wire bmp_cs,bmp_sclk,bmp_mosi;
wire [1:0] movie_bank;
wire movie_valid,movie_write_req,movie_write_en,movie_audio_valid,movie_acr_valid;
wire [31:0] movie_write_data;
wire [1:0] movie_write_bank;
wire [23:0] movie_audio_left,movie_audio_right;
wire [19:0] movie_n,movie_cts;
wire [3:0] movie_error;
wire movie_ended,movie_paused,movie_muted,movie_cs,movie_sclk,movie_mosi;
wire [15:0] movie_frame,movie_stalls;wire [31:0] movie_time_ms;
wire native_init,native_valid,native_end,movie_sec_req,bmp_sec_req,bmp_transport_reset;
wire native_initialized,native_raw_valid,native_raw_end,native_idle;
reg native_flush;
always @(posedge sd_card_clk or posedge rst_sd)begin
 if(rst_sd)native_flush<=1;
 else if(native_idle)native_flush<=0;
end
assign native_init=native_initialized && !native_flush;
assign native_valid=native_raw_valid && !native_flush && !rst_sd;
assign native_end=native_raw_end && !native_flush && !rst_sd;
wire [7:0] native_data;
wire [31:0] movie_sec_addr,bmp_sec_addr;
wire [3:0] native_error;
wire [15:0] native_retries;wire native_high_speed;wire [2:0] native_speed_status;
wire fifo_write_ready,packed_ready;
wire [4:0] movie_status;
// One sector grant is indivisible. Audio gets the next grant when needed;
// its two 1600-sample RAM banks bound demand, leaving the bus for BMP loading.
reg sd_owner;reg [1:0] sd_grant_state;
wire shared_req=sd_grant_state==1 && (sd_owner?movie_sec_req:bmp_sec_req);
wire [31:0] shared_addr=sd_owner?movie_sec_addr:bmp_sec_addr;
always @(posedge sd_card_clk or posedge rst_sd)begin
 if(rst_sd)begin sd_owner<=0;sd_grant_state<=0;end
 else if(movie_mode_sd || !native_init)begin sd_owner<=0;sd_grant_state<=0;end
 else case(sd_grant_state)
  0:if(movie_sec_req && media_active)begin sd_owner<=1;sd_grant_state<=1;end
    else if(bmp_sec_req)begin sd_owner<=0;sd_grant_state<=1;end
  1:if(native_end)sd_grant_state<=2;
  2:if(!(sd_owner?movie_sec_req:bmp_sec_req))sd_grant_state<=3;
  3:sd_grant_state<=0;
 endcase
end
wire [15:0] library_tags;wire [4:0] library_count;
reg [15:0] tag_meta,tag_video;reg [4:0] count_meta,count_video;
always @(posedge video_clk or posedge rst_video)begin
 if(rst_video)begin tag_meta<=0;tag_video<=0;count_meta<=0;count_video<=0;end
 else begin tag_meta<=library_tags;tag_video<=tag_meta;count_meta<=library_count;count_video<=count_meta;end
end
wire [3:0] full_image_id=tag_video[active_image*4+:4];

reg [19:0] rst_cnt = 20'd0;
reg rst_all_reg = 1'b1;

// Active-low seven-segment patterns: P, A and S.
localparam integer SD_CLK_HZ=83333333;
localparam [6:0] SEG_P = 7'b000_1100;
localparam [6:0] SEG_A = 7'b000_1000;
localparam [6:0] SEG_D = 7'b010_0001;







wire [3:0] ui_options;
wire [2:0] ui_selected,ui_zoom;
wire [1:0] ui_fit,ui_effect,manual_effect;
wire effect_auto;
assign ui_effect=effect_auto?full_image_id[1:0]:manual_effect;
wire play_next_n,play_select_n,play_plus_n;
wire local_next_n,local_select_n,local_plus_n;
wire caption_used,final_hs,final_vs,final_de;wire [23:0] final_rgb;wire [8:0] caption_y;
wire transition_busy;wire [1:0] transition_bank,transition_image,transition_effect;
wire [5:0] transition_progress;wire [43:0] native_widths,native_heights;
wire [5:0] movie_sec_count,bmp_sec_count;
wire scanline_reader_busy,scanline_writer_busy;wire [15:0] display_underruns;
wire signed [3:0] ui_brightness;
wire [2:0] ui_contrast;wire [3:0] ui_volume;
wire [4:0] photo_fade;
wire adj_hs,adj_vs,adj_de,wave_hs,wave_vs,wave_de;
wire [23:0] wave_rgb;
wire [23:0] adj_rgb;
reg [43:0] native_w_meta,native_h_meta,native_w_video,native_h_video;
// R6 control clocks/resets are independent of replay and media reinitialization.
wire hmi_rst_board,hmi_rst_video,hmi_rst_sd;
wire hmi_control_arst=!rst_n || !sys_pll_lock || !video_pll_lock;
reset_release hmi_reset_board(.clk(clk),.arst(hmi_control_arst),.rst(hmi_rst_board));
reset_release hmi_reset_video(.clk(video_clk),.arst(hmi_control_arst),.rst(hmi_rst_video));
reset_release hmi_reset_sd(.clk(sd_card_clk),.arst(hmi_control_arst),.rst(hmi_rst_sd));
wire hmi_link_valid,hmi_link_done,hmi_service_valid,hmi_service_done;
wire [7:0] hmi_link_op,hmi_link_object;wire [31:0] hmi_link_value;
wire [47:0] hmi_service_command;wire [39:0] hmi_link_response,hmi_service_response;
wire [15:0] hmi_crc_errors,hmi_framing_errors,hmi_busy_drops,hmi_session;
assign hmi_tx=1'b1; // UART belongs to controller B.
wire [67:0] rpc_result;wire rpc_result_commit;
bq_control_target command_target(.clk(clk),.rst(hmi_rst_board),.online(net_peer && !net_stale),.request_state(net_rx_state),
 .command_valid(hmi_link_valid),.command({hmi_link_op,hmi_link_object,hmi_link_value}),
 .command_done(hmi_link_done),.response(hmi_link_response),.result_state(rpc_result),.result_commit(rpc_result_commit));
// glyph transactions stay in the 50 MHz domain; ordinary media keeps
// its original mailbox and frame-applied acknowledgement contract.
wire caption_rpc=hmi_link_op==8'h50;
wire media_rpc_done,caption_rpc_done;wire [39:0] media_rpc_response;
wire [7:0] caption_rpc_code;wire [31:0] caption_rpc_result;
wire [5:0] custom_count;wire [15:0] custom_epoch,custom_serial;wire [8:0] custom_settings;
wire custom_frame;wire [9:0] custom_address;wire [31:0] custom_bits;
assign hmi_link_done=media_rpc_done || caption_rpc_done;
assign hmi_link_response=caption_rpc_done?{caption_rpc_code,caption_rpc_result}:media_rpc_response;
bq_caption_endpoint custom_endpoint(.clk(clk),.rst(hmi_rst_board),.valid(hmi_link_valid && caption_rpc),
 .operation(hmi_link_object[7:3]!=0?3'd7:hmi_link_object[2:0]),.value(hmi_link_value),
 .done(caption_rpc_done),.code(caption_rpc_code),.result(caption_rpc_result),
 .video_clk(video_clk),.video_rst(hmi_rst_video),.frame_start(custom_frame),.row_address(custom_address),.row_bits(custom_bits),
 .visible_count(custom_count),.visible_epoch(custom_epoch),.display_serial(custom_serial),.visible_settings(custom_settings),
 .applied_epoch(),.applied_count(),.applied_settings());
hmi_mailbox hmi_to_video(.source_clk(clk),.source_rst(hmi_rst_board),.dest_clk(video_clk),.dest_rst(hmi_rst_video),
 .source_valid(hmi_link_valid && !caption_rpc),.source_command({hmi_link_op,hmi_link_object,hmi_link_value}),
 .source_done(media_rpc_done),.source_response(media_rpc_response),.dest_valid(hmi_service_valid),
 .dest_command(hmi_service_command),.dest_done(hmi_service_done),.dest_response(hmi_service_response));
wire hmi_ui_valid;wire [3:0] hmi_ui_field;wire [7:0] hmi_ui_value;
wire hmi_photo_muted,hmi_caption_enabled;wire [1:0] hmi_caption_motion;wire [5:0] hmi_caption_speed;
wire hmi_sd_valid_source,hmi_sd_done_source,hmi_sd_valid;
wire [47:0] hmi_sd_command_source,hmi_sd_command;wire [39:0] hmi_sd_response_source;
wire hmi_sd_done;wire [39:0] hmi_sd_response;
hmi_mailbox hmi_to_sd(.source_clk(video_clk),.source_rst(hmi_rst_video),.dest_clk(sd_card_clk),.dest_rst(hmi_rst_sd),
 .source_valid(hmi_sd_valid_source),.source_command(hmi_sd_command_source),.source_done(hmi_sd_done_source),.source_response(hmi_sd_response_source),
 .dest_valid(hmi_sd_valid),.dest_command(hmi_sd_command),.dest_done(hmi_sd_done),.dest_response(hmi_sd_response));
wire hmi_restart_toggle;wire [1:0] hmi_restart_mode;wire [2:0] hmi_restart_chapter;
(* async_reg="true" *) reg [1:0] hmi_restart_sync;
reg hmi_restart_seen,hmi_restart_active;reg [16:0] hmi_restart_count;
always @(posedge clk or posedge hmi_rst_board)begin
 if(hmi_rst_board)begin hmi_restart_sync<=0;hmi_restart_seen<=0;hmi_restart_count<=0;hmi_restart_active<=0;end
 else begin
  hmi_restart_sync<={hmi_restart_sync[0],hmi_restart_toggle};
  if(hmi_restart_sync[1]!=hmi_restart_seen)begin hmi_restart_seen<=hmi_restart_sync[1];hmi_restart_count<=100000;hmi_restart_active<=1;end
  else if(hmi_restart_count!=0)begin hmi_restart_count<=hmi_restart_count-1'b1;if(hmi_restart_count==1)hmi_restart_active<=0;end
 end
end
reg hmi_vs_d;
always @(posedge video_clk or posedge hmi_rst_video)if(hmi_rst_video)hmi_vs_d<=1;else hmi_vs_d<=vs;
wire [15:0] hmi_catalog_data;wire hmi_catalog_ready;wire hmi_catalog_height;wire [15:0] hmi_failed_files;
wire hmi_photo_busy;wire [3:0] hmi_current_media;
(* async_reg="true" *) reg [1:0] hmi_photo_busy_sync;
always @(posedge video_clk or posedge rst_video)if(rst_video)hmi_photo_busy_sync<=0;else hmi_photo_busy_sync<={hmi_photo_busy_sync[0],hmi_photo_busy};
hmi_service touch_service(.clk(video_clk),.rst(hmi_rst_video),.media_ready(!rst_video),.frame_tick(hmi_vs_d && !vs),
 .valid(hmi_service_valid),.command(hmi_service_command),.done(hmi_service_done),.response(hmi_service_response),
 .ui_valid(hmi_ui_valid),.ui_field(hmi_ui_field),.ui_value(hmi_ui_value),
 .sd_valid(hmi_sd_valid_source),.sd_command(hmi_sd_command_source),.sd_done(hmi_sd_done_source),.sd_response(hmi_sd_response_source),
 .restart_toggle(hmi_restart_toggle),.restart_mode(hmi_restart_mode),.restart_chapter(hmi_restart_chapter),
 .current_chapter(chapter_video),
 .movie(movie_mode),.tone(1'b0),.display_valid(video_display_valid),.photo_busy(hmi_photo_busy_sync[1]),
 .photo_paused(video_status[10]),.photo_auto(video_status[9]),.period(video_status[8:7]),.photo_count(count_video),.photo_id(full_image_id),
 .native_w(movie_mode?11'd1280:native_w_video[active_image*11+:11]),.native_h(movie_mode?11'd720:native_h_video[active_image*11+:11]),
 .paused(movie_mode?movie_paused:photo_pause_sync[1]),.muted(movie_mode?movie_muted:hmi_photo_muted),.ended(movie_mode && movie_ended),
 .shown_frame(movie_mode?movie_frame:16'd0),.total_frames({3'd0,movie_total}),.stalls(movie_stalls),.underruns(display_underruns),
 .media_error(movie_mode?movie_status[3:0]:video_status[6:3]),.native_error(4'd0),.native_retries(16'd0),
 .brightness(ui_brightness),.contrast(ui_contrast),.zoom(ui_zoom),.fit(ui_fit),.effect(ui_effect),.volume(ui_volume),.options(ui_options),
 .photo_muted(hmi_photo_muted),.caption_enabled(hmi_caption_enabled),.caption_motion(hmi_caption_motion),.caption_speed(hmi_caption_speed));

// A media remains the clock authority; B sends transactional commands.
wire [127:0] net_rx_state;wire [59:0] net_tx_media;
wire net_rx_update,net_tx_update,net_tx_ready;
wire net_link,net_peer,net_stale,net_found,net_mdio_fault;
wire [4:0] net_phy_addr;wire [31:0] net_phy_id,net_tx_count,net_rx_count,net_errors,net_retries;
(* ASYNC_REG="TRUE" *) reg [1:0] net_arm;
always @(posedge clk or posedge hmi_rst_board)
 if(hmi_rst_board)net_arm<=0;else net_arm<={net_arm[0],switches[3]};
reg [15:0] media_epoch;reg media_ready_d,media_paused_d;
wire media_paused=movie_mode?movie_paused:photo_pause_sync[1];
wire [3:0] current_poi=movie_mode ? (movie_time_ms<20000 ? 4'd1:movie_time_ms<37000 ? 4'd2:movie_time_ms<57000 ? 4'd4:4'd3):
 // Originals 0..3 stay rose/baihui/rare/hibiscus; posters 4..7 follow movie order.
 (full_image_id==4'd6 ? 4'd4:full_image_id==4'd7 ? 4'd3:{2'd0,full_image_id[1:0]}+4'd1);
always @(posedge video_clk or posedge hmi_rst_video)
 if(hmi_rst_video)begin media_epoch<=0;media_ready_d<=0;media_paused_d<=0;end
 else begin
  media_ready_d<=!rst_video;media_paused_d<=media_paused;
  if(!media_ready_d && !rst_video)media_epoch<=media_epoch+1'b1;
 end
wire [59:0] media_state={media_epoch,movie_mode?movie_time_ms:32'd0,
 media_paused,movie_mode,video_display_valid && !rst_video,video_status[9],full_image_id,current_poi};
bq_cdc_mailbox #(.WIDTH(60)) state_to_net(.src_clk(video_clk),.src_rst_n(!hmi_rst_video),
 .src_data(media_state),.src_valid((hmi_vs_d && !vs) || media_paused!=media_paused_d),.src_ready(net_tx_ready),
 .dst_clk(clk),.dst_rst_n(!hmi_rst_board),.dst_data(net_tx_media),.dst_valid(net_tx_update),.dst_ready(1'b1));
bq_network_link #(.BOARD_ID(1)) u_network(.clk(clk),.rst(hmi_rst_board),.io_enable(net_arm[1]),
 .local_state({net_tx_media,rpc_result}),.local_state_commit(net_tx_update || rpc_result_commit),.remote_state(net_rx_state),.remote_update(net_rx_update),
 .link_up(net_link),.peer_online(net_peer),.stale(net_stale),.phy_found(net_found),.phy_addr(net_phy_addr),.phy_id(net_phy_id),
 .tx_count(net_tx_count),.rx_count(net_rx_count),.error_count(net_errors),.retry_count(net_retries),.mdio_fault(net_mdio_fault),
 .phy_rxc(phy_rxc),.phy_rxd(phy_rxd),.phy_rxctl(phy_rxctl),.phy_txc(phy_txc),.phy_txd(phy_txd),
 .phy_txctl(phy_txctl),.phy_mdc(phy_mdc),.phy_mdio(phy_mdio));

wire hmi_photo_valid,hmi_movie_valid;wire [2:0] hmi_photo_op;
wire hmi_photo_done;wire [7:0] hmi_photo_code;
wire [3:0] hmi_nav_target;
wire [7:0] hmi_sd_object=hmi_sd_command[39:32];
hmi_media_adapter touch_media(
 .clk(sd_card_clk),.rst(hmi_rst_sd),.media_reset(rst_sd),.movie(movie_mode_sd),
 .valid(hmi_sd_valid),.command(hmi_sd_command),.done(hmi_sd_done),.response(hmi_sd_response),
 .photo_valid(hmi_photo_valid),.movie_valid(hmi_movie_valid),.photo_op(hmi_photo_op),
 .photo_done(hmi_photo_done),.photo_code(hmi_photo_code),.photo_target(hmi_nav_target),
 .photo_count(library_count),.native_error(native_error),.native_retries(native_retries),.native_high_speed(native_high_speed),.native_speed_status(native_speed_status),
 .catalog_height(hmi_catalog_height),.catalog_data(hmi_catalog_data),.catalog_ready(hmi_catalog_ready));

// HDMI 1.4b 相关



assign play_next_n=local_next_n;
assign play_select_n=local_select_n;
assign play_plus_n=local_plus_n;
media_controls #(.REMOTE_ENABLE(1)) controls(.clk(video_clk),.rst(rst_video),.switches({1'b0,switches[2:0]}),
 .next_n(key1),.select_n(key_period),.plus_n(key2),.options(ui_options),
 .remote_valid(hmi_ui_valid),.remote_field(hmi_ui_field),.remote_value(hmi_ui_value),
 .photo_muted(hmi_photo_muted),.caption_enabled(hmi_caption_enabled),.caption_motion(hmi_caption_motion),.caption_speed(hmi_caption_speed),
 .selected(ui_selected),.brightness(ui_brightness),.contrast(ui_contrast),
 .fit(ui_fit),.zoom(ui_zoom),.effect(manual_effect),.effect_auto(effect_auto),.volume(ui_volume),
 .playback_next_n(local_next_n),.playback_select_n(local_select_n),.playback_plus_n(local_plus_n));
picture_adjust adjust(.clk(video_clk),.rst(rst_video),.hs(hs),.vs(vs),.de(de),.rgb(vout_data),
 .brightness(ui_brightness),.contrast(ui_contrast),.fade(movie_mode?5'd16:photo_fade),.out_hs(adj_hs),.out_vs(adj_vs),.out_de(adj_de),.out_rgb(adj_rgb));

audio_wave_overlay wave(.clk(video_clk),.rst(rst_video),.hs(adj_hs),.vs(adj_vs),.de(adj_de),.rgb(adj_rgb),
 .enabled(ui_options[2]),.movie_mode(movie_mode),.audio_valid(audio_valid),.audio_left(audio_left),
 .out_hs(wave_hs),.out_vs(wave_vs),.out_de(wave_de),.out_rgb(wave_rgb));
// 统一复位：TF 图像链路 + HDMI 链路
frame_bundle_commit #(.WIDTH(11)) status_commit(
 .source_clk(sd_card_clk),.dest_clk(video_clk),.source_rst(rst_sd),.dest_rst(rst_video),
 .requested({slide_paused,debug_auto_play_en,period_mode,(native_error!=0?4'he:state_code),debug_found_count}),
 .frame_req(video_read_req),.commit_ack(),.active(video_status));
e1_overlay #(.EXTERNAL_CAPTION(1)) status_overlay(.clk(video_clk),.rst(rst_video),.hs(wave_hs),.vs(wave_vs),.de(wave_de),
 .native_width(native_w_video[active_image*11+:11]),.native_height(native_h_video[active_image*11+:11]),.display_underruns(display_underruns),
 .caption_external(caption_used),.options(ui_options),.selected(ui_selected),.brightness(ui_brightness),.contrast(ui_contrast),
 .fit(ui_fit),.zoom(ui_zoom),.effect(ui_effect),.volume(ui_volume),
 .source_clk(sd_card_clk),.source_rst(rst_sd),.ui_write(ui_write),.ui_address(ui_address),.ui_data(ui_data),
 .ui_loaded(ui_loaded),.total_frames(movie_total),.out_hs(overlay_hs),.out_vs(overlay_vs),.out_de(overlay_de),
 .rgb(wave_rgb),.movie_mode(movie_mode),.movie_frame(movie_frame),.movie_stalls(movie_stalls),
 .movie_paused(movie_paused),.movie_muted(movie_muted),.movie_ended(movie_status[4]),.movie_error(movie_status[3:0]),.image_valid(video_display_valid),.image_id(full_image_id),.image_count(count_video),.photo_music(music_mode),
 .status(video_status),.out_rgb(vout_with_status));
reset_release reset_sd(.clk(sd_card_clk),.arst(rst_all),.rst(rst_sd));
reset_release reset_mem(.clk(ext_mem_clk),.arst(rst_all),.rst(rst_mem));
reset_release reset_video(.clk(video_clk),.arst(rst_all),.rst(rst_video));
photo_transition_commit #(.ENABLE(TRANSITIONS),.AUTO_BY_IMAGE(1)) display_commit(
 .sd_clk(sd_card_clk),.video_clk(video_clk),.rst_sd(rst_sd),.rst_video(rst_video),
 .requested_image(requested_image),.active_image(active_image),
 .requested_valid(bmp_valid),.requested_buffer(bmp_disp_bank),
 .frame_req(video_read_req),.commit_ack(display_commit_ack),
 .active_valid(bmp_video_valid),.active_buffer(bmp_video_bank),.fade(photo_fade),
 .effect(manual_effect),.effect_auto(effect_auto),.requested_effect(library_tags[requested_image*4+:2]),.transition_busy(transition_busy),.target_buffer(transition_bank),.target_image(transition_image),
 .active_effect(transition_effect),.progress(transition_progress));


// VIDEO-001: hold KEY3 through reset release to select movie mode in this bitstream.
key_press_debounce #(.CLK_FREQ_HZ(74166667),.DEBOUNCE_MS(50)) replay_button(
 .clk(video_clk),.rst(!rst_n),.button_in(play_next_n),.press_pulse(replay_press));
always @(posedge clk)begin
 if(rst_all_reg)begin movie_mode_boot<=!key_period;chapter_boot<=0;end
 else if(hmi_restart_sync[1]!=hmi_restart_seen)begin movie_mode_boot<=hmi_restart_mode==1;chapter_boot<=hmi_restart_chapter;end
 else if(replay_reset_sync[1])chapter_boot<=0;
end
// Local replay returns to the full film. Held chapter metadata has many
// reset clocks to settle before either media domain leaves reset.
(* async_reg="true" *) reg [1:0] replay_reset_sync=0;
always @(posedge clk)replay_reset_sync<={replay_reset_sync[0],replay_count!=0};
// Replay controls originate in pixel clock. Keep their debounce and reset
// stretcher here; all destination reset_release blocks release synchronously.
always @(posedge video_clk)begin
 if(!rst_n)replay_count<=0;
 else if(movie_mode && replay_press)replay_count<=32;
 else if(replay_count!=0)replay_count<=replay_count-1'b1;
end
assign movie_status[4]=movie_ended;
frame_bundle_commit #(.WIDTH(4)) movie_status_commit(
 .source_clk(sd_card_clk),.dest_clk(video_clk),.source_rst(rst_sd),.dest_rst(rst_video),
 .requested(native_error!=0?4'he:movie_error),.frame_req(video_read_req),.commit_ack(),.active(movie_status[3:0]));
// A physical-card recovery invalidates BOTH clients, not just the BMP cursor.
// Otherwise an interrupted music sector can leave a grant permanently waiting.
wire movie_reset_sd=rst_sd | !media_active | !native_init | (music_restart!=0);
wire movie_reset_video;
wire movie_pixel_valid;
reset_release reset_music_video(.clk(video_clk),.arst(rst_video | movie_reset_sd),.rst(movie_reset_video));
sd_movie #(.EXTERNAL_PCM(1),.VISIBLE_START(1),.CLK_FREQ_HZ(SD_CLK_HZ),.EXTERNAL_SD(NATIVE_SD),.REMOTE_ENABLE(1),.SEGMENT_ENABLE(1)) movie(.audio_only(!movie_mode_sd),.chapter(chapter_sd),.clk(sd_card_clk),.rst(movie_reset_sd),.video_clk(video_clk),.video_rst(movie_reset_video),
 .remote_valid(hmi_movie_valid),.remote_mute(hmi_sd_command[39:32]==8),.remote_value(hmi_sd_command[0]),
 .frame_req(video_read_req),.photo_pause(slide_paused),.video_present(movie_pixel_valid),.key_pause(movie_mode?play_plus_n:1'b1),.key_mute(movie_mode?play_select_n:1'b1),
 .write_req(movie_write_req),.write_ack(sd_card_write_req_ack && movie_mode_sd),.write_ready(fifo_write_ready),
 .write_en(movie_write_en),.write_data(movie_write_data),.write_bank(movie_write_bank),
 .write_finish_toggle(frame_write_toggle_mem),.display_valid(movie_valid),.display_bank(movie_bank),
 .audio_valid(movie_audio_valid),.audio_left(movie_audio_left),.audio_right(movie_audio_right),
 .acr_valid(movie_acr_valid),.acr_n(movie_n),.acr_cts(movie_cts),.error_code(movie_error),.ended(movie_ended),
 .paused(movie_paused),.muted(movie_muted),.shown_frame(movie_frame),.stalls(movie_stalls),.media_time_ms(movie_time_ms),
 .ui_write(ui_write),.ui_address(ui_address),.ui_data(ui_data),.ui_loaded(ui_loaded),.total_frames(movie_total),
 .ext_init(native_init),.ext_valid(native_valid && (movie_mode_sd || sd_owner)),.ext_end(native_end && (movie_mode_sd || sd_owner)),.ext_data(native_data),
 .ext_req(movie_sec_req),.ext_addr(movie_sec_addr),.ext_count(movie_sec_count),.SD_nCS(movie_cs),.SD_DCLK(movie_sclk),.SD_MOSI(movie_mosi),.SD_MISO(sd_miso));
assign sd_ncs=NATIVE_SD ? 1'bz : (movie_mode_sd ? movie_cs : bmp_cs);
assign sd_mosi=NATIVE_SD ? 1'bz : (movie_mode_sd ? movie_mosi : bmp_mosi);
generate if(NATIVE_SD)begin:native_card
 sd_native_read #(.MAX_BURST(16)) transport(.clk(sd_card_clk),.rst(hmi_rst_sd | (!movie_mode_sd && bmp_transport_reset)),
  .sd_clk(sd_dclk),.sd_cmd(sd_mosi),.sd_dat({sd_ncs,sd_dat2,sd_dat1,sd_miso}),
  .initialized(native_initialized),.transaction_idle(native_idle),
  .read_req(!rst_sd && !native_flush && (movie_mode_sd?movie_sec_req:shared_req)),
  .read_addr(movie_mode_sd?movie_sec_addr:shared_addr),.read_count((movie_mode_sd || sd_owner)?movie_sec_count:bmp_sec_count),.read_data(native_data),
  .read_valid(native_raw_valid),.read_end(native_raw_end),.error_code(native_error),.retries(native_retries),.high_speed(native_high_speed),.speed_status(native_speed_status));
end else begin:legacy_card
 assign sd_dclk=movie_mode_sd?movie_sclk:bmp_sclk;
 assign native_initialized=0;assign native_raw_valid=0;assign native_raw_end=0;assign native_idle=0;assign native_data=0;
 assign native_error=0;assign native_retries=0;
end endgenerate
assign sd_card_write_req=movie_mode_sd ? movie_write_req : bmp_write_req;
assign sd_card_write_en=movie_mode_sd ? movie_write_en : bmp_write_en;
assign sd_card_write_data=movie_mode_sd ? movie_write_data : bmp_write_data;
assign write_buf_idx=movie_mode_sd ? movie_write_bank : bmp_write_bank;
assign disp_buf_idx=bmp_disp_bank;
assign display_valid=movie_mode ? movie_valid : bmp_valid;
assign video_display_valid=movie_mode ? movie_valid : bmp_video_valid;
assign video_display_buffer=movie_mode ? movie_bank : bmp_video_bank;
// Video-only +1.94 dB headroom compensation. Current narrated PCM peak is -5.15 dBFS,
// so 5/4 gain does not clip this asset; saturation protects future loud media.
// Register before the shared gain multiplier to retain its timing margin.
function [23:0] video_headroom;
 input [23:0] value;reg signed [24:0] wide;
 begin
  wide=$signed({value[23],value})+($signed({value[23],value})>>>2);
  if(wide>25'sd8388607)video_headroom=24'h7fffff;
  else if(wide< -25'sd8388608)video_headroom=24'h800000;
  else video_headroom=wide[23:0];
 end
endfunction
reg pcm_input_valid;reg [23:0] pcm_input_left,pcm_input_right;
always @(posedge video_clk or posedge rst_video)begin
 if(rst_video)begin pcm_input_valid<=0;pcm_input_left<=0;pcm_input_right<=0;end
 else begin
  pcm_input_valid<=movie_audio_valid;
  pcm_input_left<=movie_mode?video_headroom(movie_audio_left):movie_audio_left;
  pcm_input_right<=movie_mode?video_headroom(movie_audio_right):movie_audio_right;
 end
end
audio_volume volume_stage(.clk(video_clk),.rst(rst_video),
 .in_valid(pcm_input_valid),
 .in_left(pcm_input_left),.in_right(pcm_input_right),
 .volume(ui_volume),.paused(movie_mode?movie_paused:(photo_pause_sync[1] || hmi_photo_muted)),
 .out_valid(audio_valid),.out_left(audio_left),.out_right(audio_right));
assign acr_valid=movie_acr_valid;
assign acr_n=movie_n;
assign acr_cts=movie_cts;


always @(posedge clk) begin
    if (!rst_n) begin
        rst_cnt <= 20'd0;
        rst_all_reg <= 1'b1;
    end else if (sys_pll_lock && video_pll_lock) begin
        // 等待 PLL 连续稳定 20ms @ 50MHz
        if (rst_cnt < 20'd1_000_000) begin
            rst_cnt <= rst_cnt + 1'b1;
            rst_all_reg <= 1'b1;
        end else begin
            rst_all_reg <= 1'b0;
        end
    end else begin
        rst_cnt <= 20'd0;
        rst_all_reg <= 1'b1;
    end
end

assign rst_all = hmi_restart_active | (replay_count!=0) | rst_all_reg | !sys_pll_lock | !video_pll_lock | !rst_n;

// 保持你原来的 TF / SDRAM / video 时钟
sys_pll sys_pll_m0(
    .refclk     (clk),
    .reset      (1'b0),
    .extlock    (sys_pll_lock),
    .clk0_out   (sd_card_clk),
    .clk1_out   (ext_mem_clk),
    .clk2_out   (ext_mem_clk_sft)
);

video_pll video_pll_m0(
    .refclk     (clk),
    .reset      (1'b0),
    .extlock    (video_pll_lock),
    .clk0_out   (video_clk),
    .clk1_out   (hdmi_5x_clk)
);

// mem_clk 域把 write_finish 单拍转成 toggle，供 sd_card_clk 域可靠同步
always @(posedge ext_mem_clk or posedge rst_mem) begin
    if (rst_mem)
        frame_write_toggle_mem <= 1'b0;
    else if (frame_write_finish)
        frame_write_toggle_mem <= ~frame_write_toggle_mem;
end

// ===================== TF 多图扫描与缓存（双缓冲） =====================
generate if(PHOTO_LIBRARY)begin: library_mode
photo_library #(.CLK_FREQ_HZ(SD_CLK_HZ),.REMOTE_ENABLE(1)) library_player(.clk(sd_card_clk),.rst(rst_sd | movie_mode_sd),
 .remote_valid(hmi_photo_valid),.remote_op(hmi_photo_op),.remote_value(hmi_sd_command[4:0]),
 .remote_done(hmi_photo_done),.remote_code(hmi_photo_code),.remote_id(hmi_nav_target),.catalog_index(hmi_sd_object[3:0]),.catalog_height(hmi_catalog_height),.catalog_data(hmi_catalog_data),.catalog_ready(hmi_catalog_ready),
 .failed_files(hmi_failed_files),.control_busy(hmi_photo_busy),.current_media(hmi_current_media),
 .key_next(play_next_n),.key_auto(play_plus_n),.key_period(play_select_n),
 .displayed_image(requested_image),.period_mode(period_mode),.display_valid(bmp_valid),.state_code(state_code),
 .debug_found_count(debug_found_count),.catalog_count(library_count),.bank_tags(library_tags),
 .debug_auto_play_en(debug_auto_play_en),.slide_paused(slide_paused),.display_commit_ack(display_commit_ack),
 .write_finish_toggle(frame_write_toggle_mem),.write_buf_idx(bmp_write_bank),.disp_buf_idx(bmp_disp_bank),
 .write_req(bmp_write_req),.write_req_ack(sd_card_write_req_ack && !movie_mode_sd),.write_ready(fifo_write_ready),
 .write_en(bmp_write_en),.write_data(bmp_write_data),.ext_init(native_init),
 .ext_valid(native_valid && !sd_owner),.ext_end(native_end && !sd_owner),.ext_data(native_data),
 .ext_req(bmp_sec_req),.ext_addr(bmp_sec_addr),.ext_count(bmp_sec_count),.ext_reset(bmp_transport_reset),
 .native_widths(native_widths),.native_heights(native_heights));
assign bmp_cs=1;assign bmp_sclk=0;assign bmp_mosi=1;
end else begin: legacy_photos
assign bmp_sec_count=6'd1;
assign hmi_nav_target=0;assign hmi_photo_done=0;assign hmi_photo_code=3;assign hmi_catalog_data=0;assign hmi_catalog_ready=1;assign hmi_failed_files=0;assign hmi_photo_busy=0;assign hmi_current_media=0;
assign library_count={2'd0,debug_found_count};assign library_tags=16'h3210;
sd_card_bmp #(
    .EXTERNAL_SD(NATIVE_SD),
    .CLK_FREQ_HZ       (SD_CLK_HZ),
    .SCAN_START_SECTOR (32'd0),
    .SCAN_MAX_SECTOR   (32'd131071),
    .SCAN_TARGET_COUNT (3'd4)
) sd_card_bmp_m0(
    .clk               (sd_card_clk),
    .rst               (rst_sd | movie_mode_sd),
    .key_next          (play_next_n),
    .key_auto          (play_plus_n),
    .key_period        (play_select_n),
    .displayed_image   (requested_image),
    .period_mode       (period_mode),
    .state_code        (state_code),
    .bmp_width         (16'd640),
    .bmp_height        (16'd480),
    .display_valid     (bmp_valid),
    .debug_found_count (debug_found_count),
    .debug_auto_play_en(debug_auto_play_en),.slide_paused(slide_paused),

    .display_commit_ack(display_commit_ack),
    .write_finish_toggle(frame_write_toggle_mem),
    .write_buf_idx     (bmp_write_bank),
    .disp_buf_idx      (bmp_disp_bank),

    .write_req         (bmp_write_req),
    .write_req_ack     (sd_card_write_req_ack && !movie_mode_sd),
    .write_ready       (packed_ready),
    .write_en          (bmp_write_en),
    .write_data        (bmp_write_data),
    .ext_init(native_init),.ext_valid(native_valid && !sd_owner),.ext_end(native_end && !sd_owner),.ext_data(native_data),
    .ext_req(bmp_sec_req),.ext_addr(bmp_sec_addr),.ext_reset(bmp_transport_reset),
    .native_widths(native_widths),.native_heights(native_heights),
    .SD_nCS            (bmp_cs),
    .SD_DCLK           (bmp_sclk),
    .SD_MOSI           (bmp_mosi),
    .SD_MISO           (sd_miso)
);
end endgenerate

demo_sevenseg #(.CLK_HZ(74166667),.VIDEO_FPS(30)) sevenseg(.clk(video_clk),.rst(rst_video),.movie_mode(movie_mode),
 .valid(video_display_valid),.image_id(full_image_id),.photo_music(music_mode),.period(video_status[8:7]),
 .auto_play(video_status[9]),.error_code(movie_mode ? movie_status[3:0] : video_status[6:3]),
 .paused(movie_mode?movie_paused:video_status[10]),.muted(movie_muted),.ended(movie_status[4]),.movie_frame(movie_frame),
 .seg_sel(seg_sel),.seg_data(seg_data));

// ===================== 原图像时序与帧缓存 =====================
video_timing_data video_timing_data_m0(
    .video_clk         (video_clk),
    .rst               (hmi_rst_video),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0)
);

assign video_read_req_ack=video_read_req;
assign video_read_en=de_0;
// Catalog dimensions are published before their cache-valid frame handshake.
// Two pixel-domain stages settle the immutable bundle before geometry setup.
always @(posedge video_clk or posedge rst_video)begin
 if(rst_video)begin
  native_w_meta<={4{11'd640}};native_h_meta<={4{11'd480}};
  native_w_video<={4{11'd640}};native_h_video<={4{11'd480}};
 end else begin
  native_w_meta<=native_widths;native_h_meta<=native_heights;
  native_w_video<=native_w_meta;native_h_video<=native_h_meta;
 end
end
scanline_display display_reader(
 .mem_clk(ext_mem_clk),.pixel_clk(video_clk),.rst_mem(rst_mem),.rst_pixel(rst_video),
 .init_done(Sdr_init_done),.refresh(Sdr_init_ref_vld),.busy(Sdr_busy),.writer_busy(scanline_writer_busy),
 .read_valid(Sdr_rd_en),.read_data(Sdr_rd_dout),.read_enable(App_rd_en),.read_address(App_rd_addr),.reader_busy(scanline_reader_busy),
 .hs(hs_0),.vs(vs_0),.de(de_0),.valid(video_display_valid),.movie(movie_mode),
 .bank_a(video_display_buffer),.bank_b(transition_bank),
 .native_wa(native_w_video[active_image*11+:11]),.native_ha(native_h_video[active_image*11+:11]),
 .native_wb(native_w_video[transition_image*11+:11]),.native_hb(native_h_video[transition_image*11+:11]),
 .fit(ui_fit),.zoom(ui_zoom),.effect(transition_effect),.transition(transition_busy && !movie_mode),.progress(transition_progress),
 .out_hs(hs),.out_vs(vs),.out_de(de),.out_rgb(vout_data_raw),.underruns(display_underruns),.caption_y(caption_y),.content_valid(movie_pixel_valid));

// 首图提交前黑屏；提交后一直显示当前显示缓冲区内容
assign vout_data = video_display_valid ? vout_data_raw : 24'd0;

wire packed_valid;wire [31:0] packed_data;
rgb565_pack frame_packer(.clk(sd_card_clk),.rst(rst_sd),.frame_reset(sd_card_write_req || sd_card_write_req_ack),
 .valid(sd_card_write_en),.rgb(sd_card_write_data[31:8]),.ready(packed_ready),.input_ready(fifo_write_ready),
 .out_valid(packed_valid),.data(packed_data));
frame_read_write #(
    .EXTERNAL_READER  (1),
    .BURST_SIZE       (128),
    .WRITE_V_FLIP     (1),
    .FRAME_WIDTH      (640),
    .FRAME_HEIGHT     (960)
) frame_read_write_m0(
    .mem_clk           (ext_mem_clk),
    .external_reader_busy(scanline_reader_busy),.writer_busy(scanline_writer_busy),
    .rst               (rst_mem),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),

    .App_rd_en         (),
    .App_rd_addr       (),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout),

    .read_clk          (video_clk),
    .read_req          (video_read_req),
    .read_req_ack      (),
    .read_finish       (),
    .read_addr_0       (BUF0_ADDR),
    .read_addr_1       (BUF1_ADDR),
    .read_addr_2       (21'd1228800),
    .read_addr_3       (21'd0),
    .read_addr_index   (video_display_buffer),
    .read_len          (FRAME_PIXELS),
    .read_en           (video_read_en),
    .read_data         (video_read_data),

    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_din        (App_wr_din),
    .App_wr_dm         (App_wr_dm),

    .write_clk         (sd_card_clk),
    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_finish      (frame_write_finish),
    .write_addr_0      (movie_mode_sd ? 21'd76800 : BUF0_ADDR),
    .write_addr_1      (movie_mode_sd ? 21'd691200 : BUF1_ADDR),
    .write_addr_2      (movie_mode_sd ? 21'd1305600 : 21'd1228800),
    .write_addr_3      (21'd0),
    .write_addr_index  (write_buf_idx),
    .write_len         (movie_mode_sd ? 21'd460800 : FRAME_PIXELS),
    .write_en          (packed_valid),
    .write_ready       (packed_ready),
    .write_data        (packed_data)
);

sdram U3(
    .Clk               (ext_mem_clk),
    .Clk_sft           (ext_mem_clk_sft),
    .Rst               (rst_mem),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),
    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_dm         (App_wr_dm),
    .App_wr_din        (App_wr_din),
    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout)
);

wire photo_caption_hs,photo_caption_vs,photo_caption_de,photo_caption_used,movie_caption_used;
wire [23:0] photo_caption_rgb,narration_rgb;
wire narration_hs,narration_vs,narration_de;
// Empty/cleared text returns ownership to the outlined built-in caption.
// Both image-caption renderers use the current shared caption service switch.
// A stale legacy A-only switch must not override the HMI's reported state.
// The legacy switch continues to control video narration independently.
wire custom_has_text=custom_epoch!=0 && custom_count!=0;
wire custom_visible=!movie_mode && !ui_options[3] && video_display_valid && custom_has_text && custom_settings[0];
caption_overlay captions(.clk(video_clk),.rst(rst_video),
 .hs(overlay_hs),.vs(overlay_vs),.de(overlay_de),.enabled(!movie_mode && !ui_options[3] && video_display_valid && custom_settings[0] && !custom_has_text),.scrolling(custom_settings[2:1]!=0),.speed(custom_settings[8:3]),.rgb(vout_with_status),.caption_y(caption_y),
 .out_hs(photo_caption_hs),.out_vs(photo_caption_vs),.out_de(photo_caption_de),.out_rgb(photo_caption_rgb),.caption_used(photo_caption_used));
a_timed_subtitle narration(.clk(video_clk),.rst(rst_video),.hs(photo_caption_hs),.vs(photo_caption_vs),.de(photo_caption_de),.rgb(photo_caption_rgb),
 .enabled(movie_mode && !ui_options[3] && video_display_valid && hmi_caption_enabled),.ended(movie_ended),.media_ms(movie_time_ms),
 .out_hs(narration_hs),.out_vs(narration_vs),.out_de(narration_de),.out_rgb(narration_rgb),.caption_used(movie_caption_used),.cue_id());
bq_caption_overlay #(.HEIGHT(960),.DYNAMIC_Y(1)) custom_overlay(.clk(video_clk),.rst(hmi_rst_video),
 .hs(narration_hs),.vs(narration_vs),.de(narration_de),.rgb(narration_rgb),.enabled(custom_visible),
 .scrolling(custom_settings[2:1]!=0),.paused(photo_pause_sync[1]),.speed(custom_settings[8:3]),
 .char_count(custom_count),.epoch(custom_serial),.position_y({caption_y,1'b0}),
 .frame_start(custom_frame),.row_address(custom_address),.row_bits(custom_bits),
 .out_hs(final_hs),.out_vs(final_vs),.out_de(final_de),.out_rgb(final_rgb));
assign caption_used=photo_caption_used || movie_caption_used || (custom_visible && custom_count!=0);
// Match the 23-cycle RGB compositor latency while keeping the HDMI raster
// uninterrupted through a media reset (2+3+3+4+2+7+2 stages).
reg [22:0] continuous_vs,continuous_de;
always @(posedge video_clk or posedge hmi_rst_video)begin
 if(hmi_rst_video)begin continuous_vs<=0;continuous_de<=0;end
 else begin continuous_vs<={continuous_vs[21:0],vs_0};continuous_de<={continuous_de[21:0],de_0};end
end
// ===================== RGB/DE 转 AXIS 视频 =====================
video_rgb_to_axis_640x480 u_video_rgb_to_axis_640x480(
    .I_clk         (video_clk),
    .I_rst         (hmi_rst_video),
    .I_vs          (continuous_vs[22]),
    .I_de          (continuous_de[22]),
    .I_rgb         (rst_video?24'd0:final_rgb),
    .O_video_user  (axis_s_user),
    .O_video_valid (axis_s_valid),
    .O_video_last  (axis_s_last),
    .O_video_data  (axis_s_data)
);

// 上电后自动打一拍，触发一次 EDID 读取
startup_pulse #(
    .CNT_MAX(20'd100000)
) u_startup_pulse (
    .I_clk   (video_clk),
    .I_rst   (hmi_rst_video),
    .O_pulse (edid_trig)
);

// ===================== HDMI 1.4b 发射 =====================
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE                 ( "EG"       ),
    .HTOTAL                 ( 1480 ),
    .HSA                    ( 32 ),
    .HFP                    ( 48 ),
    .HBP                    ( 120 ),
    .HACTIVE                ( 1280 ),
    .VTOTAL                 ( 1000 ),
    .VSA                    ( 3 ),
    .VFP                    ( 8 ),
    .VBP                    ( 29 ),
    .VACTIVE                ( 960 ),
    .VIDEO_VIC              ( 0 ),
    .VIDEO_TPG              ( "Disable"  ),
    .VIDEO_FORMAT           ( "RGB"      ),
    .AUDIO_SAMPLE_RATE      ( "48K"      ),
    .IIC_SCL_DIV            ( 742 )
) u_hdmi_1_4b_transmitter_core_wrapper(
    .I_pixel_clk        (video_clk),
    .I_rst              (hmi_rst_video),
    .I_edid_read_trig   (edid_trig),
    .O_edid_read_valid  (edid_valid),
    .O_edid_read_data   (edid_data),

    .I_axis_s_user      (axis_s_user),
    .I_axis_s_valid     (axis_s_valid),
    .I_axis_s_last      (axis_s_last),
    .I_axis_s_data      (axis_s_data),
    .O_axis_s_ready     (axis_s_ready),

    .I_audio_valid      (audio_valid),
    .I_audio_left_data  (audio_left),
    .I_audio_right_data (audio_right),
    .I_acr_valid        (acr_valid),
    .I_acr_cts          (acr_cts),
    .I_acr_n            (acr_n),

    .O_video_locked     (),
    .O_ddc_scl          (HDMI_DDC_SCL),
    .IO_ddc_sda         (HDMI_DDC_SDA),

    .O_ch0_tmds_data    (tmds_ch0_data),
    .O_ch1_tmds_data    (tmds_ch1_data),
    .O_ch2_tmds_data    (tmds_ch2_data),
    .O_clk_tmds_data    (tmds_clk_data)
);

hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi2phy_wrapper(
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (hmi_rst_video),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

endmodule
