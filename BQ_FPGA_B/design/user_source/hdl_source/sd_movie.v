// FAT16 HXV source + sector SPI transport + movie consumer, no extra processor.
module sd_movie #(parameter EXTERNAL_SD=0,parameter REMOTE_ENABLE=0)(
 input clk,rst,video_clk,video_rst,frame_req,input audio_only,
 input key_pause,key_mute,photo_pause,
 input remote_valid,remote_mute,remote_value,
 output write_req,input write_ack,input write_ready,
 output write_en,output [31:0] write_data,output [1:0] write_bank,
 input write_finish_toggle,
 output display_valid,output [1:0] display_bank,
 output audio_valid,output [23:0] audio_left,audio_right,
 output acr_valid,output [19:0] acr_n,acr_cts,
 output [3:0] error_code,output ended,paused,muted,
 output [15:0] shown_frame,stalls,
 output ui_write,output [8:0] ui_address,output [7:0] ui_data,output ui_loaded,output [12:0] total_frames,
 output SD_nCS,SD_DCLK,SD_MOSI,input SD_MISO,
 input ext_init,ext_valid,ext_end,input [7:0] ext_data,
 output ext_req,output [31:0] ext_addr,output [4:0] ext_count
);
wire initialized,sec_req,sec_valid,sec_end,ready,scan_done,found,stream_valid,sector_ready;
wire [31:0] sec_addr,found_cluster,stream_size;
wire [7:0] sec_data;
wire [23:0] stream_data;
wire [3:0] source_state;
reg scan_start,load_start,kicked,loaded;
reg [31:0] cluster;
reg [3:0] source_error;
wire pause_press,mute_press;
reg pause_toggle,mute_toggle,mute_armed;
key_press_debounce #(.CLK_FREQ_HZ(100000000),.DEBOUNCE_MS(50)) pause_button(
 .clk(clk),.rst(rst),.button_in(key_pause),.press_pulse(pause_press));
key_press_debounce #(.CLK_FREQ_HZ(100000000),.DEBOUNCE_MS(50)) mute_button(
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
fat16_movie_read source(.audio_only(audio_only),
 .clk(clk),.rst(rst),.scan_start(scan_start),.scan_resume(kicked && !loaded && cluster==0),
 .load_start(load_start),.load_abort(1'b0),.sd_init_done(initialized),
 .scan_start_sector(32'd0),.scan_max_sector(32'hffffffff),.load_sector(cluster),.scan_target_count(3'd1),
 .bmp_width(16'd640),.bmp_height(16'd480),.ready(ready),.scan_done(scan_done),.scan_found_valid(found),
 .scan_found_sector(found_cluster),.scan_found_total(),.state_code(source_state),.write_req(),.write_req_ack(1'b1),
 .sd_sec_read(sec_req),.sd_sec_read_addr(sec_addr),.sd_sec_read_data(sec_data),
 .sd_sec_read_data_valid(sec_valid),.sd_sec_read_end(sec_end),.bmp_data_wr_en(stream_valid),.bmp_data(stream_data),
 .sector_ready(sector_ready),.stream_size(stream_size),.sd_read_count(ext_count));
movie_player player(.audio_only(audio_only),.clk(clk),.rst(rst),.video_clk(video_clk),.video_rst(video_rst),
 .byte_valid(stream_valid),.byte_data(stream_data[7:0]),.file_size(stream_size),.source_error(source_error),
 .sector_ready(sector_ready),.write_req(write_req),.write_ack(write_ack),.write_ready(write_ready),
 .write_en(write_en),.write_data(write_data),.write_bank(write_bank),.write_finish_toggle(write_finish_toggle),
 .frame_req(frame_req),.pause_toggle(audio_only?photo_pause:pause_toggle),.mute_toggle(mute_toggle),
 .display_valid(display_valid),.display_bank(display_bank),.audio_valid(audio_valid),.audio_left(audio_left),.audio_right(audio_right),
 .acr_valid(acr_valid),.acr_n(acr_n),.acr_cts(acr_cts),.error_code(error_code),.ended(ended),
 .paused(paused),.muted(muted),.shown_frame(shown_frame),.stalls(stalls),.ui_write(ui_write),.ui_address(ui_address),.ui_data(ui_data),.ui_loaded(ui_loaded),.total_frames(total_frames));
wire legacy_init,legacy_valid,legacy_end;
wire [7:0] legacy_data;
assign ext_req=sec_req;
assign ext_addr=sec_addr;
assign initialized=EXTERNAL_SD?ext_init:legacy_init;
assign sec_data=EXTERNAL_SD?ext_data:legacy_data;
assign sec_valid=EXTERNAL_SD?ext_valid:legacy_valid;
assign sec_end=EXTERNAL_SD?ext_end:legacy_end;
sd_card_top transport(.clk(clk),.rst(rst | (EXTERNAL_SD!=0)),.SD_nCS(SD_nCS),.SD_DCLK(SD_DCLK),.SD_MOSI(SD_MOSI),.SD_MISO(SD_MISO),
 .sd_init_done(legacy_init),.sd_sec_read(sec_req),.sd_sec_read_addr(sec_addr),.sd_sec_read_data(legacy_data),
 .sd_sec_read_data_valid(legacy_valid),.sd_sec_read_end(legacy_end),.sd_sec_write(1'b0),.sd_sec_write_addr(32'd0),
 .sd_sec_write_data(8'd0),.sd_sec_write_data_req(),.sd_sec_write_end());
endmodule
