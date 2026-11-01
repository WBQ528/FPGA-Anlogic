// R5 HXAV0005: native960x540/24fps, 4x4 blocks, 2000 PCM samples.
// Upscale 4/3 in FPGA to packed1280x720. Never publish an all-dark frame.
// 4x4 block: RGB565 endpoints + 16 two-bit indices; quarter palette interpolation.
// Two audio banks, three SDRAM video banks: released audio never overwrites a
// video frame still being scanned. Audio is the time base; frame swap is atomic.
// Input sectors are indivisible; five compressed row bands overlap SD refill
// with rendering. Only CRC-complete SD sectors enter this ring.
module movie_player #(
 parameter integer SAMPLE_CYCLES=74166667,
 parameter integer SAMPLE_RATE=48000,
 parameter integer SAMPLES=2000,
 parameter integer LOAD_TIMEOUT=200000000
)(
 input clk,rst,video_clk,video_rst,input audio_only,
 input byte_valid,input [7:0] byte_data,input [31:0] file_size,input [3:0] source_error,
 output sector_ready,
 output reg write_req,input write_ack,input write_ready,
 output write_en,output [31:0] write_data,output [1:0] write_bank,
 input write_finish_toggle,input frame_req,
 input pause_toggle,input mute_toggle,
 output reg display_valid,output reg [1:0] display_bank,
 output reg audio_valid,output reg [23:0] audio_left,audio_right,
 output reg acr_valid,output [19:0] acr_n,acr_cts,
 output reg [3:0] error_code,output reg ended,
 output reg paused,output reg muted,output reg [15:0] shown_frame,
 output reg [15:0] stalls,
 output ui_write,output [8:0] ui_address,output [7:0] ui_data,output ui_loaded,output [12:0] total_frames
);
localparam HEADER=0,CHECK=1,REQUEST=2,ACK_LOW=3,AUDIO=4,PICTURE=5,DRAIN=6,PUBLISH=7,WAIT_ACK=8,DONE=9,ERROR=10,PADDING=11;
reg [3:0] state;
reg [8:0] header_pos;
reg [63:0] magic;
reg [31:0] frame_count,h_rate,h_fps,h_packet,h_length;
reg [15:0] h_width,h_height;
// CHECK rejects zero and counts above 8191 before any packet is accepted.
// The zero-based producer index reaches at most 8191 at terminal consume.
reg [12:0] frame_index;
reg [22:0] packet_count;
reg [31:0] expected_length;
reg [27:0] load_watchdog;
reg [13:0] audio_byte;
reg [17:0] picture_byte;
reg [2:0] block_byte;reg [10:0] band_byte;reg [8:0] padding_byte;
reg version4,version3,version_audio;
reg header_bad;
wire end_block=block_byte==3'd7;
wire crosses_band=band_byte>11'd1408;
reg [7:0] low_byte;
reg bank,ready_toggle,source_eof;
reg [1:0] video_bank;
reg [2:0] finish_sync;
reg finish_baseline;
reg [1:0] ack_sync;
reg consume_toggle;
reg [15:0] audio_ram[0:4095];
// 32-bit words map to the native 512x18 dual-port RAM organization. Split
// 2048+512 avoids depth rounding. Fetch both halves once per 4-pixel block.
reg [31:0] block_main[0:2047],block_tail[0:511];
reg [63:0] block_shift,block_q;
reg [31:0] block_main_q,block_tail_q,block_low;
reg block_tail_select;
wire [31:0] block_word=block_tail_select?block_tail_q:block_main_q;
reg [7:0] rx_block;
reg [2:0] rx_bank;
reg [4:0] line_put,line_get;
reg render_busy;reg [2:0] render_bank;
wire [2:0] next_rx_bank=rx_bank==4 ? 3'd0 : rx_bank+3'd1;
reg [10:0] render_x;
reg [9:0] render_y;
reg [1:0] render_row;reg [2:0] render_phase;
reg [23:0] render_rgb,palette0,palette1,palette2,palette3;
reg [1:0] selected_palette;
wire black_row=1'b0;
reg [9:0] source_x;reg [1:0] x_fraction,y_fraction;
reg [10:0] lit_count;reg published_image,lit_pixel;
wire [23:0] output_color=selected_palette==0?palette0:selected_palette==1?palette1:selected_palette==2?palette2:palette3;
wire row_advance=(y_fraction!=0);
wire publishable=version_audio || lit_count==1024;

wire [7:0] block_address=source_x[9:2];
wire [3:0] pixel_in_block={render_row,source_x[1:0]};
wire [31:0] shifted_indices=block_q[63:32] >> {pixel_in_block,1'b0};
wire [1:0] palette_index=shifted_indices[1:0];
wire [23:0] c0={block_q[15:11],block_q[15:13],block_q[10:5],block_q[10:9],block_q[4:0],block_q[4:2]};
wire [23:0] c1={block_q[31:27],block_q[31:29],block_q[26:21],block_q[26:25],block_q[20:16],block_q[20:18]};
function [7:0] quarter;
 input [7:0] a,b;reg [9:0] sum;
 begin sum={a,1'b0}+{2'b0,a}+{2'b0,b};quarter=sum[9:2];end
endfunction
wire [23:0] decoded_rgb=palette_index==0 ? c0 : palette_index==1 ? c1 :
 palette_index==2 ? {quarter(c0[23:16],c1[23:16]),quarter(c0[15:8],c1[15:8]),quarter(c0[7:0],c1[7:0])} :
 {quarter(c1[23:16],c0[23:16]),quarter(c1[15:8],c0[15:8]),quarter(c1[7:0],c0[7:0])};
assign ui_write=state==HEADER && byte_valid;
assign ui_address=header_pos;
assign ui_data=byte_data;
assign ui_loaded=state>=REQUEST && state!=ERROR;
assign total_frames=frame_count[12:0];
assign write_en=render_busy && render_phase==4 && write_ready && state!=ERROR;
assign write_data={output_color,8'd0};
assign write_bank=video_bank;
assign sector_ready=(state==HEADER || state==AUDIO ||
 state==PADDING || (state==PICTURE && line_put[rx_bank]==line_get[rx_bank] &&
 (!crosses_band || line_put[next_rx_bank]==line_get[next_rx_bank])));
assign acr_n=20'd6144;
assign acr_cts=20'd74167;
always @(posedge clk) begin
 // Header is stable hundreds of cycles before CHECK. Decode once into a
 // register so a 64-bit magic compare never sits on streaming backpressure.
 if(rst)begin version4<=0;version3<=0;version_audio<=0;end
 else if(state==HEADER)begin
  version4<=magic==64'h3530303056415848;
  version3<=0;
  version_audio<=audio_only && magic==64'h3230303055415848; // HXAU0002 PCM packets
 end
 // 515 sectors/video packet, 8/audio packet; pipelined exact length.
 packet_count<=version_audio?({7'd0,frame_count[12:0],3'd0}):
  ({1'd0,frame_count[12:0],9'd0}+{9'd0,frame_count[12:0],1'b0}+{10'd0,frame_count[12:0]});
 expected_length<={packet_count,9'd0}+32'd512;
 // Fields end at byte 31; hundreds of byte clocks remain before CHECK.
 // Register the format/length decision instead of gating the whole FSM with
 // several 32-bit comparisons. Invalid upper count bits are still checked.
 header_bad<=(!version4 && !version3 && !version_audio) || frame_count==0 || frame_count>8191 || h_width!=960 || h_height!=540 ||
  h_rate!=48000 || h_fps!=24 || h_packet!=(version_audio?4096:263680) || h_length!=file_size || h_length!=expected_length;
 block_tail_select<=render_bank[2];
 if(render_bank[2])block_tail_q<=block_tail[{block_address,(render_phase==1)}];
 else block_main_q<=block_main[{render_bank[1:0],block_address,(render_phase==1)}];
 if(byte_valid && state==PICTURE && block_byte[1:0]==3)begin
  if(rx_bank[2])block_tail[{rx_block,block_byte[2]}]<={byte_data,block_shift[63:40]};
  else block_main[{rx_bank[1:0],rx_block,block_byte[2]}]<={byte_data,block_shift[63:40]};
 end
 if(byte_valid && state==AUDIO && audio_byte<4000 && audio_byte[0])
  audio_ram[{bank,audio_byte[11:1]}]<={byte_data,low_byte};
end
// Count committed bright pixels one cycle after color selection. DRAIN waits
// for the frame writer completion before publication, including the last pixel.
always @(posedge clk or posedge rst)begin
 if(rst)begin lit_pixel<=0;lit_count<=0;end
 else if(state==ACK_LOW && !write_ack)begin lit_pixel<=0;lit_count<=0;end
 else begin
  lit_pixel<=write_en && (|{output_color[23:20],output_color[15:12],output_color[7:4]});
  if(lit_pixel && !lit_count[10])lit_count<=lit_count+1'b1;
 end
end
always @(posedge clk or posedge rst) begin
 if(rst)begin
  render_busy<=0;render_bank<=0;render_x<=0;render_y<=0;render_row<=0;
  render_phase<=0;source_x<=0;x_fraction<=0;y_fraction<=0;line_get<=0;render_rgb<=0;palette0<=0;palette1<=0;palette2<=0;palette3<=0;selected_palette<=0;
 end else if(state==ACK_LOW && !write_ack)begin
  render_busy<=1;render_bank<=0;render_x<=0;render_y<=0;render_row<=0;render_phase<=0;source_x<=0;x_fraction<=0;y_fraction<=0;
 end else if(render_busy)begin
  case(render_phase)
   0:if(black_row || line_put[render_bank]!=line_get[render_bank])render_phase<=1;
   1:begin block_low<=block_word;render_phase<=2;end
   2:begin block_q<={block_word,block_low};render_phase<=3;end
   3:begin
    palette0<=c0;palette1<=c1;selected_palette<=palette_index;
    palette2<={quarter(c0[23:16],c1[23:16]),quarter(c0[15:8],c1[15:8]),quarter(c0[7:0],c1[7:0])};
    palette3<={quarter(c1[23:16],c0[23:16]),quarter(c1[15:8],c0[15:8]),quarter(c1[7:0],c0[7:0])};
    render_phase<=4;
   end
   4:if(write_ready)begin
    render_phase<=(x_fraction!=0 && source_x[1:0]==3)?0:3;
    if(render_x==1279)begin
     render_x<=0;source_x<=0;x_fraction<=0;render_y<=render_y+1'b1;render_phase<=0;
     y_fraction<=y_fraction+2'd3;
     if(row_advance)begin
      render_row<=render_row+1'b1;
      if(render_row==3)begin line_get[render_bank]<=line_put[render_bank];render_bank<=render_bank==4 ? 3'd0 : render_bank+3'd1;end
     end
     if(render_y==719)render_busy<=0;
    end else begin
     render_x<=render_x+1'b1;x_fraction<=x_fraction+2'd3;
     if(x_fraction!=0)source_x<=source_x+1'b1;
    end
   end
  endcase
 end
end
always @(posedge clk or posedge rst)begin
 if(rst)begin
  state<=HEADER;header_pos<=0;magic<=0;frame_count<=0;h_rate<=0;h_fps<=0;h_packet<=0;h_length<=0;
  h_width<=0;h_height<=0;frame_index<=0;audio_byte<=0;picture_byte<=0;low_byte<=0;block_byte<=0;band_byte<=0;padding_byte<=0;
  bank<=0;video_bank<=0;ready_toggle<=0;write_req<=0;finish_sync<=0;finish_baseline<=0;ack_sync<=0;
  rx_block<=0;block_shift<=0;rx_bank<=0;line_put<=0;error_code<=0;source_eof<=0;load_watchdog<=0;published_image<=0;
 end else begin
  finish_sync<={finish_sync[1:0],write_finish_toggle};ack_sync<={ack_sync[0],consume_toggle};
  case(state)
   HEADER:if(byte_valid)begin
    header_pos<=header_pos+1'b1;
    case(header_pos)
     0,1,2,3,4,5,6,7:magic<={byte_data,magic[63:8]};
     8,9,10,11:frame_count<={byte_data,frame_count[31:8]};
     12,13:h_width<={byte_data,h_width[15:8]};
     14,15:h_height<={byte_data,h_height[15:8]};
     16,17,18,19:h_rate<={byte_data,h_rate[31:8]};
     20,21,22,23:h_fps<={byte_data,h_fps[31:8]};
     24,25,26,27:h_packet<={byte_data,h_packet[31:8]};
     28,29,30,31:h_length<={byte_data,h_length[31:8]};
     default:;
    endcase
    if(header_pos==511)state<=CHECK;
   end
   CHECK:begin
    if(header_bad)begin state<=ERROR;error_code<=4'hb;end
    else state<=REQUEST;
   end
   REQUEST:begin
    if(version_audio)begin state<=AUDIO;audio_byte<=0;end
    else begin write_req<=1;finish_baseline<=finish_sync[2];if(write_ack)begin write_req<=0;state<=ACK_LOW;end end
   end
   ACK_LOW:if(!write_ack)begin state<=AUDIO;audio_byte<=0;picture_byte<=0;rx_bank<=0;rx_block<=0;end
   AUDIO:if(byte_valid)begin
    low_byte<=byte_data;audio_byte<=audio_byte+1'b1;
    if(audio_byte==4095)begin state<=version_audio?PUBLISH:PICTURE;picture_byte<=0;block_byte<=0;band_byte<=0;end
   end
   PICTURE:if(byte_valid)begin
    block_shift<={byte_data,block_shift[63:8]};picture_byte<=picture_byte+1'b1;
    block_byte<=end_block?3'd0:block_byte+1'b1;
    band_byte<=band_byte==11'd1919 ? 11'd0 : band_byte+1'b1;
    if(end_block)begin
     if(line_put[rx_bank]!=line_get[rx_bank])begin state<=ERROR;error_code<=4'hc;end
     if(rx_block==239)begin rx_block<=0;line_put[rx_bank]<=~line_put[rx_bank];rx_bank<=next_rx_bank;end
     else rx_block<=rx_block+1'b1;
    end
    if(picture_byte==18'd259199 && line_put[rx_bank]==line_get[rx_bank])begin
     state<=version4?PADDING:DRAIN;padding_byte<=0;
    end
   end
   PADDING:if(byte_valid)begin padding_byte<=padding_byte+1'b1;if(padding_byte==383)state<=DRAIN;end
   DRAIN:if(finish_sync[2]!=finish_baseline && !render_busy && line_get==line_put)state<=PUBLISH;
   PUBLISH:begin published_image<=publishable;ready_toggle<=~ready_toggle;state<=WAIT_ACK;end
   WAIT_ACK:if(ack_sync[1]==ready_toggle)begin
    frame_index<=frame_index+13'd1;bank<=~bank;if(published_image)video_bank<=video_bank==2 ? 0 : video_bank+1'b1;
    if(frame_index+13'd1==frame_count[12:0])begin state<=DONE;source_eof<=1;end else state<=REQUEST;
   end
   DONE:;
   ERROR:write_req<=0;
   default:begin state<=ERROR;error_code<=4'he;end
  endcase
  if((state>=REQUEST && state<=DRAIN) || state==PADDING)begin
   load_watchdog<=load_watchdog+1'b1;
   if(load_watchdog>=LOAD_TIMEOUT-1)begin state<=ERROR;error_code<=4'he;write_req<=0;end
  end else load_watchdog<=0;
  if(source_error!=0)begin state<=ERROR;error_code<=source_error;write_req<=0;end
 end
end

// Video domain: exact audio sample clock is the media time base. Video changes only
// at a raster boundary; audio blocks switch every 2000 samples without cumulative drift.
// Three video banks let the producer run while the previous frame finishes scanning.
reg [1:0] ready_sync,pause_sync,mute_sync;
reg seen_ready,pause_seen,mute_seen,pending,pending_bank;
reg [1:0] pending_video_bank,next_video_bank;
reg audio_bank,audio_running,video_pending,pending_image,next_image;
reg [10:0] sample_index;
reg [26:0] sample_phase;
reg [5:0] acr_count;
reg frame_d;
reg [15:0] pcm_q;
reg [1:0] error_sync,end_sync;
wire sample_tick=(sample_phase>=SAMPLE_CYCLES-SAMPLE_RATE);
always @(posedge video_clk) pcm_q<=audio_ram[{audio_bank,sample_index}];
always @(posedge video_clk or posedge video_rst)begin
 if(video_rst)begin
  ready_sync<=0;pause_sync<=0;mute_sync<=0;error_sync<=0;end_sync<=0;seen_ready<=0;pause_seen<=0;mute_seen<=0;
  pending<=0;pending_bank<=0;pending_video_bank<=0;next_video_bank<=0;audio_bank<=0;audio_running<=0;video_pending<=0;pending_image<=0;next_image<=0;
  sample_index<=0;sample_phase<=0;acr_count<=0;frame_d<=0;
  display_valid<=0;display_bank<=0;consume_toggle<=0;audio_valid<=0;audio_left<=0;audio_right<=0;
  ended<=0;acr_valid<=0;paused<=0;muted<=0;shown_frame<=0;stalls<=0;
 end else begin
  ready_sync<={ready_sync[0],ready_toggle};pause_sync<={pause_sync[0],pause_toggle};mute_sync<={mute_sync[0],mute_toggle};
  error_sync<={error_sync[0],error_code!=0};end_sync<={end_sync[0],source_eof};frame_d<=frame_req;audio_valid<=0;acr_valid<=0;
  if(end_sync[1] && display_valid && !audio_running && !video_pending && !pending)ended<=1;
  if(pause_sync[1]!=pause_seen)begin pause_seen<=pause_sync[1];paused<=~paused;end
  if(mute_sync[1]!=mute_seen)begin mute_seen<=mute_sync[1];muted<=~muted;end
  if(ready_sync[1]!=seen_ready)begin
   seen_ready<=ready_sync[1];pending<=1;pending_bank<=bank;pending_video_bank<=video_bank;pending_image<=published_image;
  end
  if(!display_valid && pending && !pending_image)begin pending<=0;consume_toggle<=seen_ready;end
  if(frame_req && !frame_d && !paused)begin
   if(!display_valid && pending && pending_image)begin
    display_valid<=1;display_bank<=pending_video_bank;audio_bank<=pending_bank;
    pending<=0;audio_running<=1;sample_index<=0;consume_toggle<=seen_ready;shown_frame<=1;
   end else if(video_pending)begin
    if(next_image)display_bank<=next_video_bank;video_pending<=0;shown_frame<=shown_frame+1'b1;
   end
  end
  if(sample_tick)begin
   sample_phase<=sample_phase+SAMPLE_RATE-SAMPLE_CYCLES;audio_valid<=1;
   if(acr_count==47)begin acr_count<=0;acr_valid<=1;end else acr_count<=acr_count+1'b1;
   audio_left<=0;audio_right<=0;
   if(audio_running && !paused && !error_sync[1])begin
    if(!muted)begin audio_left<={pcm_q,8'd0};audio_right<={pcm_q,8'd0};end
    if(sample_index==SAMPLES-1)begin
     audio_running<=0;sample_index<=0;
     if(pending)begin
      audio_bank<=pending_bank;pending<=0;audio_running<=1;video_pending<=1;
      next_video_bank<=pending_video_bank;next_image<=pending_image;consume_toggle<=seen_ready;
     end else if(!end_sync[1] && stalls!=65535)stalls<=stalls+1'b1;
    end else sample_index<=sample_index+1'b1;
   end else if(display_valid && pending && !paused && !error_sync[1] && !video_pending)begin
    audio_bank<=pending_bank;sample_index<=0;pending<=0;audio_running<=1;video_pending<=1;
    next_video_bank<=pending_video_bank;next_image<=pending_image;consume_toggle<=seen_ready;
   end
  end else sample_phase<=sample_phase+SAMPLE_RATE;
 end
end
endmodule
