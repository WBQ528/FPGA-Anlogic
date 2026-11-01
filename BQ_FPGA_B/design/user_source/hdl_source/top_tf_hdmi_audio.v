

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
    input hmi_rx,output hmi_tx
);

parameter MEM_DATA_BITS = 32;
parameter ADDR_BITS     = 21;
parameter BUSRT_BITS    = 10;
parameter [ADDR_BITS-1:0] FRAME_PIXELS = 21'd460800;   // 1280*720/2 packed RGB565 words
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
reg movie_mode_boot=0,photo_tone_mode_boot=0;
(* async_reg="true" *) reg [1:0] mode_video_sync=0,tone_video_sync=0,mode_sd_sync=0,tone_sd_sync=0;
always @(posedge video_clk)begin mode_video_sync<={mode_video_sync[0],movie_mode_boot};tone_video_sync<={tone_video_sync[0],photo_tone_mode_boot};end
always @(posedge sd_card_clk)begin mode_sd_sync<={mode_sd_sync[0],movie_mode_boot};tone_sd_sync<={tone_sd_sync[0],photo_tone_mode_boot};end
wire movie_mode=mode_video_sync[1],photo_tone_mode=tone_video_sync[1];
wire movie_mode_sd=mode_sd_sync[1];
wire music_mode_sd=PHOTO_MUSIC && NATIVE_SD && !movie_mode_sd && !tone_sd_sync[1];
wire music_mode=PHOTO_MUSIC && NATIVE_SD && !movie_mode && !photo_tone_mode;
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
reg [5:0] music_restart;reg [1:0] ended_sync;
always @(posedge sd_card_clk or posedge rst_sd)begin
 if(rst_sd)begin music_restart<=0;ended_sync<=0;end
 else begin
  ended_sync<={ended_sync[0],movie_ended};
  if(music_restart!=0)music_restart<=music_restart-1'b1;
  else if(music_mode_sd && ended_sync[1])music_restart<=32;
 end
end
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
wire [15:0] movie_frame,movie_stalls;
wire native_init,native_valid,native_end,movie_sec_req,bmp_sec_req,bmp_transport_reset;
wire [7:0] native_data;
wire [31:0] movie_sec_addr,bmp_sec_addr;
wire [3:0] native_error;
wire [15:0] native_retries;
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

wire tone_valid,tone_acr_valid;
wire [23:0] tone_left,tone_right;
wire [19:0] tone_n,tone_cts;
reg [19:0] rst_cnt = 20'd0;
reg rst_all_reg = 1'b1;

// Active-low seven-segment patterns: P, A and S.
localparam [6:0] SEG_P = 7'b000_1100;
localparam [6:0] SEG_A = 7'b000_1000;
localparam [6:0] SEG_D = 7'b010_0001;







wire [3:0] ui_options;
wire [2:0] ui_selected,ui_zoom;
wire [1:0] ui_fit,ui_effect;
wire play_next_n,play_select_n,play_plus_n;
wire local_next_n,local_select_n,local_plus_n;
wire caption_used,final_hs,final_vs,final_de;wire [23:0] final_rgb;wire [8:0] caption_y;
wire transition_busy;wire [1:0] transition_bank,transition_image,transition_effect;
wire [5:0] transition_progress;wire [43:0] native_widths,native_heights;
wire [4:0] movie_sec_count;
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
hmi_link touch_link(.clk(clk),.rst(hmi_rst_board),.rx(hmi_rx),.tx(hmi_tx),
 .command_valid(hmi_link_valid),.command_op(hmi_link_op),.command_object(hmi_link_object),.command_value(hmi_link_value),
 .command_done(hmi_link_done),.command_code(hmi_link_response[39:32]),.command_result(hmi_link_response[31:0]),
 .crc_errors(hmi_crc_errors),.framing_errors(hmi_framing_errors),.busy_drops(hmi_busy_drops),.session_id(hmi_session));
hmi_mailbox hmi_to_video(.source_clk(clk),.source_rst(hmi_rst_board),.dest_clk(video_clk),.dest_rst(hmi_rst_video),
 .source_valid(hmi_link_valid),.source_command({hmi_link_op,hmi_link_object,hmi_link_value}),
 .source_done(hmi_link_done),.source_response(hmi_link_response),.dest_valid(hmi_service_valid),
 .dest_command(hmi_service_command),.dest_done(hmi_service_done),.dest_response(hmi_service_response));
wire hmi_ui_valid;wire [3:0] hmi_ui_field;wire [7:0] hmi_ui_value;
wire hmi_photo_muted,hmi_caption_enabled;wire [1:0] hmi_caption_motion;wire [5:0] hmi_caption_speed;
wire hmi_sd_valid_source,hmi_sd_done_source,hmi_sd_valid;
wire [47:0] hmi_sd_command_source,hmi_sd_command;wire [39:0] hmi_sd_response_source;
wire hmi_sd_done;wire [39:0] hmi_sd_response;
hmi_mailbox hmi_to_sd(.source_clk(video_clk),.source_rst(hmi_rst_video),.dest_clk(sd_card_clk),.dest_rst(hmi_rst_sd),
 .source_valid(hmi_sd_valid_source),.source_command(hmi_sd_command_source),.source_done(hmi_sd_done_source),.source_response(hmi_sd_response_source),
 .dest_valid(hmi_sd_valid),.dest_command(hmi_sd_command),.dest_done(hmi_sd_done),.dest_response(hmi_sd_response));
wire hmi_restart_toggle;wire [1:0] hmi_restart_mode;
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
 .restart_toggle(hmi_restart_toggle),.restart_mode(hmi_restart_mode),
 .movie(movie_mode),.tone(photo_tone_mode),.display_valid(video_display_valid),.photo_busy(hmi_photo_busy_sync[1]),
 .photo_paused(video_status[10]),.photo_auto(video_status[9]),.period(video_status[8:7]),.photo_count(count_video),.photo_id(full_image_id),
 .native_w(movie_mode?11'd960:native_w_video[active_image*11+:11]),.native_h(movie_mode?11'd540:native_h_video[active_image*11+:11]),
 .paused(movie_mode?movie_paused:photo_pause_sync[1]),.muted(movie_mode?movie_muted:hmi_photo_muted),.ended(movie_mode && movie_ended),
 .shown_frame(movie_mode?movie_frame:16'd0),.total_frames({3'd0,movie_total}),.stalls(movie_stalls),.underruns(display_underruns),
 .media_error(movie_mode?movie_status[3:0]:video_status[6:3]),.native_error(4'd0),.native_retries(16'd0),
 .brightness(ui_brightness),.contrast(ui_contrast),.zoom(ui_zoom),.fit(ui_fit),.effect(ui_effect),.volume(ui_volume),.options(ui_options),
 .photo_muted(hmi_photo_muted),.caption_enabled(hmi_caption_enabled),.caption_motion(hmi_caption_motion),.caption_speed(hmi_caption_speed));
wire hmi_photo_valid,hmi_movie_valid;wire [2:0] hmi_photo_op;
wire hmi_photo_done;wire [7:0] hmi_photo_code;
wire [3:0] hmi_nav_target;
wire [7:0] hmi_sd_object=hmi_sd_command[39:32];
hmi_media_adapter touch_media(
 .clk(sd_card_clk),.rst(hmi_rst_sd),.media_reset(rst_sd),.movie(movie_mode_sd),
 .valid(hmi_sd_valid),.command(hmi_sd_command),.done(hmi_sd_done),.response(hmi_sd_response),
 .photo_valid(hmi_photo_valid),.movie_valid(hmi_movie_valid),.photo_op(hmi_photo_op),
 .photo_done(hmi_photo_done),.photo_code(hmi_photo_code),.photo_target(hmi_nav_target),
 .photo_count(library_count),.native_error(native_error),.native_retries(native_retries),
 .catalog_height(hmi_catalog_height),.catalog_data(hmi_catalog_data),.catalog_ready(hmi_catalog_ready));

// HDMI 1.4b 相关



assign play_next_n=local_next_n;
assign play_select_n=local_select_n;
assign play_plus_n=local_plus_n;
media_controls #(.REMOTE_ENABLE(1)) controls(.clk(video_clk),.rst(rst_video),.switches(switches),
 .next_n(key1),.select_n(key_period),.plus_n(key2),.options(ui_options),
 .remote_valid(hmi_ui_valid),.remote_field(hmi_ui_field),.remote_value(hmi_ui_value),
 .photo_muted(hmi_photo_muted),.caption_enabled(hmi_caption_enabled),.caption_motion(hmi_caption_motion),.caption_speed(hmi_caption_speed),
 .selected(ui_selected),.brightness(ui_brightness),.contrast(ui_contrast),
 .fit(ui_fit),.zoom(ui_zoom),.effect(ui_effect),.volume(ui_volume),
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
audio_demo_pcm audio_demo(.clk(video_clk),.rst(rst_video),
 .image_valid(video_display_valid),.image_id(active_image),
 .audio_valid(tone_valid),.audio_left(tone_left),.audio_right(tone_right),
 .acr_valid(tone_acr_valid),.acr_n(tone_n),.acr_cts(tone_cts));
reset_release reset_sd(.clk(sd_card_clk),.arst(rst_all),.rst(rst_sd));
reset_release reset_mem(.clk(ext_mem_clk),.arst(rst_all),.rst(rst_mem));
reset_release reset_video(.clk(video_clk),.arst(rst_all),.rst(rst_video));
photo_transition_commit #(.ENABLE(TRANSITIONS)) display_commit(
 .sd_clk(sd_card_clk),.video_clk(video_clk),.rst_sd(rst_sd),.rst_video(rst_video),
 .requested_image(requested_image),.active_image(active_image),
 .requested_valid(bmp_valid),.requested_buffer(bmp_disp_bank),
 .frame_req(video_read_req),.commit_ack(display_commit_ack),
 .active_valid(bmp_video_valid),.active_buffer(bmp_video_bank),.fade(photo_fade),
 .effect(ui_effect),.transition_busy(transition_busy),.target_buffer(transition_bank),.target_image(transition_image),
 .active_effect(transition_effect),.progress(transition_progress));


// VIDEO-001: hold KEY3 through reset release to select movie mode in this bitstream.
key_press_debounce #(.CLK_FREQ_HZ(74166667),.DEBOUNCE_MS(50)) replay_button(
 .clk(video_clk),.rst(!rst_n),.button_in(play_next_n),.press_pulse(replay_press));
always @(posedge clk)begin
 if(rst_all_reg)begin movie_mode_boot<=!key_period;photo_tone_mode_boot<=!key1;end
 else if(hmi_restart_sync[1]!=hmi_restart_seen)begin movie_mode_boot<=hmi_restart_mode==1;photo_tone_mode_boot<=hmi_restart_mode==2;end
end
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
wire movie_reset_sd=rst_sd | !media_active | (music_restart!=0);
wire movie_reset_video;
reset_release reset_music_video(.clk(video_clk),.arst(rst_video | movie_reset_sd),.rst(movie_reset_video));
sd_movie #(.EXTERNAL_SD(NATIVE_SD),.REMOTE_ENABLE(1)) movie(.audio_only(!movie_mode_sd),.clk(sd_card_clk),.rst(movie_reset_sd),.video_clk(video_clk),.video_rst(movie_reset_video),
 .remote_valid(hmi_movie_valid),.remote_mute(hmi_sd_command[39:32]==8),.remote_value(hmi_sd_command[0]),
 .frame_req(video_read_req),.photo_pause(slide_paused),.key_pause(movie_mode?play_plus_n:1'b1),.key_mute(movie_mode?play_select_n:1'b1),
 .write_req(movie_write_req),.write_ack(sd_card_write_req_ack && movie_mode_sd),.write_ready(fifo_write_ready),
 .write_en(movie_write_en),.write_data(movie_write_data),.write_bank(movie_write_bank),
 .write_finish_toggle(frame_write_toggle_mem),.display_valid(movie_valid),.display_bank(movie_bank),
 .audio_valid(movie_audio_valid),.audio_left(movie_audio_left),.audio_right(movie_audio_right),
 .acr_valid(movie_acr_valid),.acr_n(movie_n),.acr_cts(movie_cts),.error_code(movie_error),.ended(movie_ended),
 .paused(movie_paused),.muted(movie_muted),.shown_frame(movie_frame),.stalls(movie_stalls),
 .ui_write(ui_write),.ui_address(ui_address),.ui_data(ui_data),.ui_loaded(ui_loaded),.total_frames(movie_total),
 .ext_init(native_init),.ext_valid(native_valid && (movie_mode_sd || sd_owner)),.ext_end(native_end && (movie_mode_sd || sd_owner)),.ext_data(native_data),
 .ext_req(movie_sec_req),.ext_addr(movie_sec_addr),.ext_count(movie_sec_count),.SD_nCS(movie_cs),.SD_DCLK(movie_sclk),.SD_MOSI(movie_mosi),.SD_MISO(sd_miso));
assign sd_ncs=NATIVE_SD ? 1'bz : (movie_mode_sd ? movie_cs : bmp_cs);
assign sd_mosi=NATIVE_SD ? 1'bz : (movie_mode_sd ? movie_mosi : bmp_mosi);
generate if(NATIVE_SD)begin:native_card
 sd_native_read #(.MAX_BURST(16)) transport(.clk(sd_card_clk),.rst(rst_sd | (!movie_mode_sd && bmp_transport_reset)),
  .sd_clk(sd_dclk),.sd_cmd(sd_mosi),.sd_dat({sd_ncs,sd_dat2,sd_dat1,sd_miso}),
  .initialized(native_init),.read_req(movie_mode_sd?movie_sec_req:shared_req),
  .read_addr(movie_mode_sd?movie_sec_addr:shared_addr),.read_count(movie_mode_sd?movie_sec_count:5'd1),.read_data(native_data),
  .read_valid(native_valid),.read_end(native_end),.error_code(native_error),.retries(native_retries));
end else begin:legacy_card
 assign sd_dclk=movie_mode_sd?movie_sclk:bmp_sclk;
 assign native_init=0;assign native_valid=0;assign native_end=0;assign native_data=0;
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
audio_volume volume_stage(.clk(video_clk),.rst(rst_video),
 .in_valid(pcm_select_sync[1]?movie_audio_valid:tone_valid),
 .in_left(pcm_select_sync[1]?movie_audio_left:tone_left),.in_right(pcm_select_sync[1]?movie_audio_right:tone_right),
 .volume(ui_volume),.paused(movie_mode?movie_paused:(photo_pause_sync[1] || hmi_photo_muted)),
 .out_valid(audio_valid),.out_left(audio_left),.out_right(audio_right));
assign acr_valid=pcm_select_sync[1] ? movie_acr_valid : tone_acr_valid;
assign acr_n=pcm_select_sync[1] ? movie_n : tone_n;
assign acr_cts=pcm_select_sync[1] ? movie_cts : tone_cts;


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
photo_library #(.REMOTE_ENABLE(1)) library_player(.clk(sd_card_clk),.rst(rst_sd | movie_mode_sd),
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
 .ext_req(bmp_sec_req),.ext_addr(bmp_sec_addr),.ext_reset(bmp_transport_reset),
 .native_widths(native_widths),.native_heights(native_heights));
assign bmp_cs=1;assign bmp_sclk=0;assign bmp_mosi=1;
end else begin: legacy_photos
assign hmi_nav_target=0;assign hmi_photo_done=0;assign hmi_photo_code=3;assign hmi_catalog_data=0;assign hmi_catalog_ready=1;assign hmi_failed_files=0;assign hmi_photo_busy=0;assign hmi_current_media=0;
assign library_count={2'd0,debug_found_count};assign library_tags=16'h3210;
sd_card_bmp #(
    .EXTERNAL_SD(NATIVE_SD),
    .CLK_FREQ_HZ       (100_000_000),
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

demo_sevenseg #(.CLK_HZ(74166667),.VIDEO_FPS(24)) sevenseg(.clk(video_clk),.rst(rst_video),.movie_mode(movie_mode),
 .valid(video_display_valid),.image_id(full_image_id),.photo_music(music_mode),.period(video_status[8:7]),
 .auto_play(video_status[9]),.error_code(movie_mode ? movie_status[3:0] : video_status[6:3]),
 .paused(movie_mode?movie_paused:video_status[10]),.muted(movie_muted),.ended(movie_status[4]),.movie_frame(movie_frame),
 .seg_sel(seg_sel),.seg_data(seg_data));

// ===================== 原图像时序与帧缓存 =====================
video_timing_data video_timing_data_m0(
    .video_clk         (video_clk),
    .rst               (rst_video),
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
 .out_hs(hs),.out_vs(vs),.out_de(de),.out_rgb(vout_data_raw),.underruns(display_underruns),.caption_y(caption_y));

// 首图提交前黑屏；提交后一直显示当前显示缓冲区内容
assign vout_data = video_display_valid ? vout_data_raw : 24'd0;

wire packed_valid;wire [31:0] packed_data;
rgb565_pack frame_packer(.clk(sd_card_clk),.rst(rst_sd),.frame_reset(sd_card_write_req || sd_card_write_req_ack),
 .valid(sd_card_write_en),.rgb(sd_card_write_data[31:8]),.ready(packed_ready),.input_ready(fifo_write_ready),
 .out_valid(packed_valid),.data(packed_data));
frame_read_write #(
    .EXTERNAL_READER  (1),
    .WRITE_V_FLIP     (1),
    .FRAME_WIDTH      (640),
    .FRAME_HEIGHT     (720)
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
    .read_addr_2       (21'd921600),
    .read_addr_3       (21'd1382400),
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
    .write_addr_0      (BUF0_ADDR),
    .write_addr_1      (BUF1_ADDR),
    .write_addr_2      (21'd921600),
    .write_addr_3      (21'd1382400),
    .write_addr_index  (write_buf_idx),
    .write_len         (FRAME_PIXELS),
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

caption_overlay captions(.clk(video_clk),.rst(rst_video),
 .hs(overlay_hs),.vs(overlay_vs),.de(overlay_de),.enabled(!ui_options[3] && video_display_valid && hmi_caption_enabled),.scrolling(hmi_caption_motion==2?!movie_mode:hmi_caption_motion==1),.speed(hmi_caption_speed),.rgb(vout_with_status),.caption_y(caption_y),
 .out_hs(final_hs),.out_vs(final_vs),.out_de(final_de),.out_rgb(final_rgb),.caption_used(caption_used));
// ===================== RGB/DE 转 AXIS 视频 =====================
video_rgb_to_axis_640x480 u_video_rgb_to_axis_640x480(
    .I_clk         (video_clk),
    .I_rst         (rst_video),
    .I_vs          (final_vs),
    .I_de          (final_de),
    .I_rgb         (final_rgb),
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
    .I_rst   (rst_video),
    .O_pulse (edid_trig)
);

// ===================== HDMI 1.4b 发射 =====================
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE                 ( "EG"       ),
    .HTOTAL                 ( 1650 ),
    .HSA                    ( 40 ),
    .HFP                    ( 110 ),
    .HBP                    ( 220 ),
    .HACTIVE                ( 1280 ),
    .VTOTAL                 ( 750 ),
    .VSA                    ( 5 ),
    .VFP                    ( 5 ),
    .VBP                    ( 20 ),
    .VACTIVE                ( 720 ),
    .VIDEO_VIC              ( 4 ),
    .VIDEO_TPG              ( "Disable"  ),
    .VIDEO_FORMAT           ( "RGB"      ),
    .AUDIO_SAMPLE_RATE      ( "48K"      ),
    .IIC_SCL_DIV            ( 742 )
) u_hdmi_1_4b_transmitter_core_wrapper(
    .I_pixel_clk        (video_clk),
    .I_rst              (rst_video),
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
    .I_rst              (rst_video),
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
