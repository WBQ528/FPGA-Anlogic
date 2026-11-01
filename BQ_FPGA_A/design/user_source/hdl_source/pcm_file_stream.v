// independent FAT16 PCM cursor and 4096-sample asynchronous reservoir.
// Metadata is supplied by the validated movie mount/root-directory scan.
// No video-ready dependency after startup; audio is the media clock.
module pcm_file_stream #(
 parameter integer CLOCK_RATE=74166667, SAMPLE_RATE=48000, TIMEOUT=166666666
)(
 input clk,rst,pixel_clk,pixel_rst,enable,initialized,metadata_valid,
 input [31:0] fat_base,data_base,file_bytes,
 input [16:0] cluster_limit,input [15:0] first_cluster,
 input [7:0] sectors_per_cluster,input [3:0] cluster_shift,
 input [12:0] first_frame,limit_frame,total_frames,input [31:0] start_ms,
 output reg request,output reg [31:0] address,output [5:0] read_count,
 input byte_valid,sector_end,input [7:0] byte_data,
 input inline_mode,inline_valid,input [15:0] inline_data,input inline_end,output inline_ready,
 input video_ready,paused,muted,
 output reg audio_valid,output reg [23:0] audio_left,audio_right,
 output reg [31:0] media_ms,output reg [12:0] media_frame,
 output reg ended,output reg [15:0] underruns,output reg [3:0] error,
 output [12:0] level
);
localparam IDLE=0,SEEK=1,FAT_REQUEST=2,FAT_READ=3,FAT_CHECK=4,
 ADDRESS=5,WAIT_SPACE=6,DATA_READ=7,NEXT=8,FINISH=9,FAIL=10,ADDRESS_SHIFT=11,ADDRESS_ADD=12,
 PARAM_WAIT=13,PARAM_CHECK=14;
reg [3:0] state;
reg [15:0] cluster,next_cluster;reg [7:0] cluster_sector;
reg [15:0] seek_sectors;reg [23:0] remaining_samples;
reg [8:0] first_skip;reg [9:0] byte_index;reg [7:0] lo;
reg [27:0] watchdog;reg seeking,source_done;
reg [23:0] address_offset;reg [3:0] shift_left;
reg [12:0] write_pointer,write_gray,read_pointer,read_gray;
(* ASYNC_REG="TRUE" *) reg [12:0] read_sync0,read_sync1,write_sync0,write_sync1;
function [12:0] binary;input [12:0] gray;integer i;begin
 binary[12]=gray[12];for(i=11;i>=0;i=i-1)binary[i]=binary[i+1]^gray[i];
end endfunction
wire [12:0] used=write_pointer-binary(read_sync1);
wire [12:0] available=binary(write_sync1)-read_pointer;
assign level=available;
wire [12:0] final_frame=limit_frame!=0?limit_frame:total_frames;
(* dsp_style="yes" *) reg [23:0] start_sample,stop_sample;
always @(posedge clk)begin start_sample<=first_frame*16'd1600;stop_sample<=final_frame*16'd1600;end
// Parameters are held for the entire media session. Register the decoded
// chapter bundle before crossing into the pixel domain; only use it after
// the synchronizer has settled, before the PCM reservoir starts draining.
reg [12:0] first_frame_sd,final_frame_sd;
reg [31:0] start_ms_sd;
reg bounds_valid;
always @(posedge clk)begin
 first_frame_sd<=first_frame;final_frame_sd<=final_frame;start_ms_sd<=start_ms;
 bounds_valid<=first_cluster>=2 && {1'b0,first_cluster}<cluster_limit &&
               stop_sample>start_sample && file_bytes>={7'd0,stop_sample,1'b0};
end
(* ASYNC_REG="TRUE" *) reg [12:0] first_frame_meta,final_frame_meta;
(* ASYNC_REG="TRUE" *) reg [31:0] start_ms_meta;
reg [12:0] first_frame_pixel,final_frame_pixel;
reg [31:0] start_ms_pixel;
(* ASYNC_REG="TRUE" *) reg [3:0] params_ready;
always @(posedge pixel_clk or posedge pixel_rst)begin
 if(pixel_rst)begin
  first_frame_meta<=0;final_frame_meta<=0;start_ms_meta<=0;
  first_frame_pixel<=0;final_frame_pixel<=0;start_ms_pixel<=0;params_ready<=0;
 end else begin
  first_frame_meta<=first_frame_sd;final_frame_meta<=final_frame_sd;start_ms_meta<=start_ms_sd;
  first_frame_pixel<=first_frame_meta;final_frame_pixel<=final_frame_meta;start_ms_pixel<=start_ms_meta;
  params_ready<={params_ready[2:0],metadata_valid || inline_mode};
 end
end
wire store=enable && (inline_mode?inline_valid:(state==DATA_READ && byte_valid && byte_index[0] &&
 (byte_index>>1)>=first_skip && remaining_samples!=0));
assign inline_ready=used<=13'd3840;
wire [15:0] write_pcm=inline_mode?inline_data:{byte_data,lo};
wire [15:0] q0,q1;reg read_bank;
always @(posedge clk or posedge rst)begin
 if(rst)begin read_sync0<=0;read_sync1<=0;write_pointer<=0;write_gray<=0;end
 else begin
  read_sync0<=read_gray;read_sync1<=read_sync0;
  if(store)begin write_pointer<=write_pointer+1'b1;write_gray<=((write_pointer+13'd1)>>1)^(write_pointer+13'd1);end
 end
end
always @(posedge pixel_clk or posedge pixel_rst)begin
 if(pixel_rst)begin write_sync0<=0;write_sync1<=0;end
 else begin write_sync0<=write_gray;write_sync1<=write_sync0;end
end
genvar k;
generate for(k=0;k<2;k=k+1)begin:ram
 wire [15:0] q;
`ifdef UI_FONT_SIM
 reg [15:0] words[0:2047];reg [15:0] qr;
 always @(posedge clk)if(store && write_pointer[11]==k)words[write_pointer[10:0]]<=write_pcm;
 always @(posedge pixel_clk)qr<=words[read_pointer[10:0]];
 assign q=qr;
`else
 EG_PHY_BRAM32K #(.MODE("DP16K"),.DATA_WIDTH_A("16"),.DATA_WIDTH_B("16"),
 .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL")) memory(
 .doa(),.dob(q),.dia(write_pcm),.dib(16'd0),.addra(write_pointer[10:0]),.addrb(read_pointer[10:0]),
 .bytea(1'b0),.bytewea(1'b0),.byteb(1'b0),.byteweb(1'b0),.csa(1'b1),.wea(store && write_pointer[11]==k),.csb(1'b1),.web(1'b0),
 .clka(clk),.clkb(pixel_clk),.rsta(1'b0),.rstb(1'b0),.ocea(1'b1),.oceb(1'b1));
`endif
 if(k==0)assign q0=q;else assign q1=q;
end endgenerate
always @(posedge pixel_clk)read_bank<=read_pointer[11];
wire [15:0] pcm=read_bank?q1:q0;
// Only one 512-byte sector is drained at a time. A burst never crosses FAT.
wire [8:0] cluster_remaining={1'b0,sectors_per_cluster}-{1'b0,cluster_sector};
assign read_count=state==DATA_READ ? (cluster_remaining>=4?6'd4:cluster_remaining[5:0]):6'd1;
reg filling;
always @(posedge clk or posedge rst)begin
 if(rst)begin
  state<=IDLE;request<=0;address<=0;error<=0;cluster<=0;next_cluster<=0;cluster_sector<=0;
  seek_sectors<=0;remaining_samples<=0;first_skip<=0;byte_index<=0;lo<=0;watchdog<=0;seeking<=0;source_done<=0;filling<=0;address_offset<=0;shift_left<=0;
 end else if(enable && inline_mode)begin source_done<=inline_end;end
 else if(enable)begin
  if(store)remaining_samples<=remaining_samples-1'b1;
  if(used<=2048)filling<=1;else if(used>=3584)filling<=0;
  if(request)begin
   watchdog<=watchdog+1'b1;
  end else watchdog<=0;
  case(state)
   IDLE:if(initialized && metadata_valid && total_frames!=0)state<=PARAM_WAIT;
   PARAM_WAIT:state<=PARAM_CHECK;
   PARAM_CHECK:begin
    if(!bounds_valid)begin state<=FAIL;error<=4'hb;end
    else begin
     cluster<=first_cluster;seek_sectors<=start_sample>>8;first_skip<={1'b0,start_sample[7:0]};
     remaining_samples<=stop_sample-start_sample;seeking<=1;state<=SEEK;
    end
   end
   SEEK:if(seek_sectors<sectors_per_cluster)begin cluster_sector<=seek_sectors[7:0];seeking<=0;state<=ADDRESS;end
    else begin seek_sectors<=seek_sectors-sectors_per_cluster;state<=FAT_REQUEST;end
   FAT_REQUEST:begin address<=fat_base+{24'd0,cluster[15:8]};byte_index<=0;request<=1;state<=FAT_READ;end
   FAT_READ:begin
    if(byte_valid)begin
     byte_index<=byte_index+1'b1;
     if(byte_index=={1'b0,cluster[7:0],1'b0})next_cluster[7:0]<=byte_data;
     if(byte_index=={1'b0,cluster[7:0],1'b0}+10'd1)next_cluster[15:8]<=byte_data;
    end
    if(sector_end)begin request<=0;state<=FAT_CHECK;end
   end
   FAT_CHECK:if(byte_index!=512 || next_cluster<2 || next_cluster>=16'hfff0 || {1'b0,next_cluster}>=cluster_limit || next_cluster==cluster || next_cluster==first_cluster)begin state<=FAIL;error<=4'hd;end
    else begin cluster<=next_cluster;cluster_sector<=0;state<=seeking?SEEK:ADDRESS;end
   ADDRESS:begin address_offset<={8'd0,cluster}-24'd2;shift_left<=cluster_shift;state<=ADDRESS_SHIFT;end
   ADDRESS_SHIFT:if(shift_left==0)state<=ADDRESS_ADD;else begin address_offset<=address_offset<<1;shift_left<=shift_left-1'b1;end
   ADDRESS_ADD:begin address<=data_base+{8'd0,(address_offset|{16'd0,cluster_sector})};state<=WAIT_SPACE;end
   WAIT_SPACE:if(initialized && filling && used<=3840)begin request<=1;byte_index<=0;state<=DATA_READ;end
   DATA_READ:begin
    if(byte_valid)begin lo<=byte_data;byte_index<=byte_index+1'b1;end
    if(sector_end)begin request<=0;first_skip<=0;state<=NEXT;end
   end
   NEXT:if(byte_index!=512)begin state<=FAIL;error<=4'he;end
    else if(remaining_samples==0)begin source_done<=1;state<=FINISH;end
    else if(cluster_remaining>1)begin cluster_sector<=cluster_sector+1'b1;address<=address+1'b1;state<=WAIT_SPACE;end
    else state<=FAT_REQUEST;
   FINISH:;
   FAIL:request<=0;
   default:begin state<=FAIL;error<=4'he;end
  endcase
  if(request && watchdog==TIMEOUT-1)begin request<=0;state<=FAIL;error<=4'he;end
 end
end
reg [26:0] phase;reg running,starved;
reg [10:0] frame_sample;reg [5:0] ms_sample;
`ifdef UI_FONT_SIM
reg [23:0] samples_played;
always @(posedge pixel_clk or posedge pixel_rst)
 if(pixel_rst)samples_played<=0;
 else if(tick && enable && !error_sync[1] && !ended && running && !paused && available!=0)samples_played<=samples_played+1'b1;
`endif
(* ASYNC_REG="TRUE" *) reg [1:0] done_sync,error_sync;
wire tick=phase>=CLOCK_RATE-SAMPLE_RATE;
always @(posedge pixel_clk or posedge pixel_rst)begin
 if(pixel_rst)begin
  phase<=0;read_pointer<=0;read_gray<=0;audio_valid<=0;audio_left<=0;audio_right<=0;
  running<=0;starved<=0;frame_sample<=0;ms_sample<=0;media_ms<=0;media_frame<=0;ended<=0;underruns<=0;done_sync<=0;error_sync<=0;
 end else begin
  done_sync<={done_sync[0],source_done};error_sync<={error_sync[0],error!=0};audio_valid<=0;
  if(!running && !ended)begin media_frame<=first_frame_pixel;media_ms<=start_ms_pixel;end
  if(tick)begin
   phase<=phase+SAMPLE_RATE-CLOCK_RATE;audio_valid<=1;audio_left<=0;audio_right<=0;
   if(enable && !error_sync[1] && !ended)begin
    if(!running)begin
     if(params_ready[3] && video_ready && !paused && (available>=2048 || (done_sync[1] && available!=0)))running<=1;
    end else if(!paused)begin
     if(available!=0)begin
      audio_left<=muted?24'd0:{pcm,8'd0};audio_right<=muted?24'd0:{pcm,8'd0};
      read_pointer<=read_pointer+1'b1;read_gray<=((read_pointer+13'd1)>>1)^(read_pointer+13'd1);
      starved<=0;
      if(ms_sample==47)begin ms_sample<=0;media_ms<=media_ms+1'b1;end else ms_sample<=ms_sample+1'b1;
      if(frame_sample==1599)begin frame_sample<=0;if(media_frame+1'b1<final_frame_pixel)media_frame<=media_frame+1'b1;end else frame_sample<=frame_sample+1'b1;
      if(done_sync[1] && available==1)begin ended<=1;running<=0;end
     end else if(done_sync[1])begin ended<=1;running<=0;end
     else if(!starved)begin starved<=1;if(underruns!=65535)underruns<=underruns+1'b1;end
    end
   end
  end else phase<=phase+SAMPLE_RATE;
 end
end
endmodule
