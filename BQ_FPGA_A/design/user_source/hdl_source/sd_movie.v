// FAT16 HXV source + sector SPI transport + movie consumer, no extra processor.
module sd_movie #(parameter CLK_FREQ_HZ=100000000,parameter EXTERNAL_SD=0,parameter REMOTE_ENABLE=0,parameter SEGMENT_ENABLE=0,parameter EXTERNAL_PCM=0,parameter VISIBLE_START=0)(
 input clk,rst,video_clk,video_rst,frame_req,input audio_only,
 input [2:0] chapter,
 input key_pause,key_mute,photo_pause,video_present,
 input remote_valid,remote_mute,remote_value,
 output write_req,input write_ack,input write_ready,
 output write_en,output [31:0] write_data,output [1:0] write_bank,
 input write_finish_toggle,
 output display_valid,output [1:0] display_bank,
 output audio_valid,output [23:0] audio_left,audio_right,
 output acr_valid,output [19:0] acr_n,acr_cts,
 output [3:0] error_code,output ended,paused,muted,
 output [15:0] shown_frame,stalls,output [31:0] media_time_ms,
 output ui_write,output [8:0] ui_address,output [7:0] ui_data,output ui_loaded,output [12:0] total_frames,
 output SD_nCS,SD_DCLK,SD_MOSI,input SD_MISO,
 input ext_init,ext_valid,ext_end,input [7:0] ext_data,
 output ext_req,output [31:0] ext_addr,output [5:0] ext_count
);
wire initialized,sec_req,sec_valid,sec_end,ready,scan_done,found,stream_valid,sector_ready;
wire [31:0] sec_addr,found_cluster,stream_size;
wire [7:0] sec_data;
wire [23:0] stream_data;
wire [3:0] source_state;
wire [31:0] pcm_fat_base,pcm_data_base,pcm_bytes;wire [16:0] pcm_cluster_limit;
wire [7:0] pcm_spc;wire [3:0] pcm_shift,pcm_error;wire [15:0] pcm_cluster;
wire [12:0] skip_frames,pcm_frame;wire skip_ack,pcm_request,pcm_valid,pcm_ended;
wire [31:0] pcm_address,pcm_ms;wire [5:0] pcm_count,source_count;
wire [23:0] pcm_left,pcm_right,legacy_left,legacy_right;wire [15:0] pcm_stalls,legacy_stalls;
wire legacy_audio_valid;wire [31:0] legacy_ms;
wire separate_audio=EXTERNAL_PCM!=0;
wire inline_valid,inline_end,inline_ready;wire [15:0] inline_data;
reg first_picture_seen;
always @(posedge video_clk or posedge video_rst)begin
 if(video_rst)first_picture_seen<=0;
 else if(display_valid && video_present)first_picture_seen<=1;
end
reg pcm_owner;reg [1:0] grant;
always @(posedge clk or posedge rst)begin
 if(rst)begin pcm_owner<=0;grant<=0;end
 else case(grant)
  0:if(separate_audio && pcm_request)begin pcm_owner<=1;grant<=1;end
    else if(sec_req)begin pcm_owner<=0;grant<=1;end
  1:if(ext_end)grant<=2;
  2:if(!(pcm_owner?pcm_request:sec_req))grant<=3;
  3:grant<=0;
 endcase
end
// Chapter numbers follow garden IDs; the film's order is 1,2,4,3.
// The requested chapter is held across media reset, then remains immutable
// until the next explicit restart. No extra chapter video copies on TF.
wire [2:0] clip=SEGMENT_ENABLE && !audio_only ? chapter:3'd0;
wire [12:0] clip_first=clip==2 ? 13'd600:clip==4 ? 13'd1110:clip==3 ? 13'd1710:13'd0;
wire [12:0] clip_limit=clip==1 ? 13'd600:clip==2 ? 13'd1110:clip==4 ? 13'd1710:clip==3 ? 13'd2160:13'd0;
wire [31:0] clip_ms=clip==2 ? 32'd20000:clip==4 ? 32'd37000:clip==3 ? 32'd57000:32'd0;
reg scan_start,load_start,kicked,loaded;
reg [31:0] cluster;
reg [3:0] source_error;
wire pause_press,mute_press;
reg pause_toggle,mute_toggle,mute_armed;
key_press_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ),.DEBOUNCE_MS(50)) pause_button(
 .clk(clk),.rst(rst),.button_in(key_pause),.press_pulse(pause_press));
key_press_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ),.DEBOUNCE_MS(50)) mute_button(
 .clk(clk),.rst(rst),.button_in(key_mute),.press_pulse(mute_press));
always @(posedge clk or posedge rst)begin
 if(rst)begin scan_start<=0;load_start<=0;kicked<=0;loaded<=0;cluster<=0;source_error<=0;pause_toggle<=0;mute_toggle<=0;mute_armed<=0;end
 else begin
  scan_start<=0;load_start<=0;
  if(pause_press)pause_toggle<=~pause_toggle;
  if(key_mute)mute_armed<=1;
  if(mute_press && mute_armed)mute_toggle<=~mute_toggle;
  if(REMOTE_ENABLE && remote_valid)begin
   if(remote_mute)mute_toggle<=remote_value;else pause_toggle<=!remote_value;
  end
  if(initialized && !kicked)begin scan_start<=1;kicked<=1;end
  if(found)begin cluster<=found_cluster;loaded<=1;end
  if(loaded && ready && !load_start)begin load_start<=1;loaded<=0;end
  if(source_state>=4'hb)source_error<=source_state;
  if(scan_done && !loaded && !found && cluster==0)source_error<=4'hf;
 end
end
fat16_movie_read #(.READ_TIMEOUT(CLK_FREQ_HZ*2),.SEGMENT_ENABLE(SEGMENT_ENABLE),.EXTERNAL_PCM(EXTERNAL_PCM)) source(.audio_only(audio_only),.start_frame(clip_first),
 .clk(clk),.rst(rst),.scan_start(scan_start),.scan_resume(kicked && !loaded && cluster==0),
 .load_start(load_start),.load_abort(1'b0),.sd_init_done(initialized),
 .scan_start_sector(32'd0),.scan_max_sector(32'hffffffff),.load_sector(cluster),.scan_target_count(3'd1),
 .bmp_width(16'd640),.bmp_height(16'd480),.ready(ready),.scan_done(scan_done),.scan_found_valid(found),
 .scan_found_sector(found_cluster),.scan_found_total(),.state_code(source_state),.write_req(),.write_req_ack(1'b1),
 .sd_sec_read(sec_req),.sd_sec_read_addr(sec_addr),.sd_sec_read_data(sec_data),
 .sd_sec_read_data_valid(sec_valid),.sd_sec_read_end(sec_end),.bmp_data_wr_en(stream_valid),.bmp_data(stream_data),
 .sector_ready(sector_ready),.stream_size(stream_size),.sd_read_count(source_count),
 .pcm_fat_base(pcm_fat_base),.pcm_data_base(pcm_data_base),.pcm_cluster_limit(pcm_cluster_limit),.pcm_spc(pcm_spc),.pcm_shift(pcm_shift),.pcm_cluster(pcm_cluster),.pcm_bytes(pcm_bytes),.skip_frames(skip_frames),.skip_ack(skip_ack));
movie_player #(.SEGMENT_ENABLE(SEGMENT_ENABLE),.EXTERNAL_PCM(EXTERNAL_PCM)) player(.audio_only(audio_only),.clk(clk),.rst(rst),.video_clk(video_clk),.video_rst(video_rst),
 .segment_first(clip_first),.segment_limit(clip_limit),.segment_start_ms(clip_ms),
 .byte_valid(stream_valid),.byte_data(stream_data[7:0]),.file_size(stream_size),.source_error(separate_audio && pcm_error!=0?pcm_error:source_error),
 .sector_ready(sector_ready),.write_req(write_req),.write_ack(write_ack),.write_ready(write_ready),
 .write_en(write_en),.write_data(write_data),.write_bank(write_bank),.write_finish_toggle(write_finish_toggle),
 .frame_req(frame_req),.pause_toggle(audio_only?photo_pause:pause_toggle),.mute_toggle(mute_toggle),
 .display_valid(display_valid),.display_bank(display_bank),.audio_valid(legacy_audio_valid),.audio_left(legacy_left),.audio_right(legacy_right),
 .acr_valid(acr_valid),.acr_n(acr_n),.acr_cts(acr_cts),.error_code(error_code),.ended(ended),
 .paused(paused),.muted(muted),.shown_frame(shown_frame),.stalls(legacy_stalls),.media_time_ms(legacy_ms),.ui_write(ui_write),.ui_address(ui_address),.ui_data(ui_data),.ui_loaded(ui_loaded),.total_frames(total_frames),
 .external_frame(pcm_frame),.external_ended(pcm_ended),.skip_frames(skip_frames),.skip_ack(skip_ack),
 .inline_pcm_valid(inline_valid),.inline_pcm_data(inline_data),.inline_pcm_end(inline_end),.inline_pcm_ready(inline_ready));
generate if(EXTERNAL_PCM)begin:independent_audio
 pcm_file_stream #(.TIMEOUT(CLK_FREQ_HZ*2)) pcm(.clk(clk),.rst(rst),.pixel_clk(video_clk),.pixel_rst(video_rst),
 .enable(separate_audio),.initialized(initialized),.metadata_valid(ui_loaded && pcm_cluster!=0),.fat_base(pcm_fat_base),.data_base(pcm_data_base),.file_bytes(pcm_bytes),
 .cluster_limit(pcm_cluster_limit),.first_cluster(pcm_cluster),.sectors_per_cluster(pcm_spc),.cluster_shift(pcm_shift),
 .first_frame(clip_first),.limit_frame(clip_limit),.total_frames(total_frames),.start_ms(clip_ms),
 .request(pcm_request),.address(pcm_address),.read_count(pcm_count),.byte_valid(ext_valid && pcm_owner && grant==1),.sector_end(ext_end && pcm_owner && grant==1),.byte_data(ext_data),
 .inline_mode(audio_only),.inline_valid(inline_valid),.inline_data(inline_data),.inline_end(inline_end),.inline_ready(inline_ready),
 .video_ready(display_valid && (audio_only || !VISIBLE_START || first_picture_seen)),.paused(paused),.muted(muted),.audio_valid(pcm_valid),.audio_left(pcm_left),.audio_right(pcm_right),.media_ms(pcm_ms),.media_frame(pcm_frame),
 .ended(pcm_ended),.underruns(pcm_stalls),.error(pcm_error),.level());
end else begin:no_independent_audio
 assign pcm_request=0;assign pcm_address=0;assign pcm_count=0;assign pcm_valid=0;assign pcm_left=0;assign pcm_right=0;
 assign pcm_ms=0;assign pcm_frame=0;assign pcm_ended=0;assign pcm_stalls=0;assign pcm_error=0;assign inline_ready=1;
end endgenerate
assign audio_valid=separate_audio?pcm_valid:legacy_audio_valid;
assign audio_left=separate_audio?pcm_left:legacy_left;assign audio_right=separate_audio?pcm_right:legacy_right;
assign media_time_ms=separate_audio?pcm_ms:legacy_ms;assign stalls=separate_audio?pcm_stalls:legacy_stalls;
wire legacy_init,legacy_valid,legacy_end;
wire [7:0] legacy_data;
assign ext_req=EXTERNAL_PCM?(grant==1 && (pcm_owner?pcm_request:sec_req)):sec_req;
assign ext_addr=EXTERNAL_PCM && pcm_owner?pcm_address:sec_addr;
assign ext_count=EXTERNAL_PCM && pcm_owner?pcm_count:source_count;
assign initialized=EXTERNAL_SD?ext_init:legacy_init;
assign sec_data=EXTERNAL_SD?ext_data:legacy_data;
assign sec_valid=EXTERNAL_SD?(ext_valid && (!EXTERNAL_PCM || (!pcm_owner && grant==1))):legacy_valid;
assign sec_end=EXTERNAL_SD?(ext_end && (!EXTERNAL_PCM || (!pcm_owner && grant==1))):legacy_end;
sd_card_top transport(.clk(clk),.rst(rst | (EXTERNAL_SD!=0)),.SD_nCS(SD_nCS),.SD_DCLK(SD_DCLK),.SD_MOSI(SD_MOSI),.SD_MISO(SD_MISO),
 .sd_init_done(legacy_init),.sd_sec_read(sec_req),.sd_sec_read_addr(sec_addr),.sd_sec_read_data(legacy_data),
 .sd_sec_read_data_valid(legacy_valid),.sd_sec_read_end(legacy_end),.sd_sec_write(1'b0),.sd_sec_write_addr(32'd0),
 .sd_sec_write_data(8'd0),.sd_sec_write_data_req(),.sd_sec_write_end());
endmodule
