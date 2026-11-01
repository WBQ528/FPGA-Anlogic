// R3: same transparent white capsule style for photos AND movies.
// 2.731s PCM history, smoothed attack/release. Photo mode adds a bounded,
// level-weighted zero-crossing activity term so equal-level tones can differ;
// music remains driven only by real PCM, never image ID or a generated pattern.
// Snapshot during vertical blank. Two-clock RGB/sync pipeline; disabled is idle.
module audio_wave_overlay #(parameter SAMPLES_PER_BAR=2048)(
 input clk,rst,hs,vs,de,input [23:0] rgb,
 input enabled,movie_mode,audio_valid,input [23:0] audio_left,
 output reg out_hs,out_vs,out_de,output reg [23:0] out_rgb
);
reg [5:0] history[0:63],display_bars[0:63];
reg [$clog2(SAMPLES_PER_BAR)-1:0] sample_count;reg [31:0] magnitude_sum;
reg [5:0] write_pos,envelope;reg [6:0] filled;
reg enabled_f,movie_f,vs_d,de_d;reg [10:0] physical_x;wire [9:0] x=physical_x[10:1];reg [1:0] row_phase;reg [8:0] y;
reg copying;reg [5:0] copy_pos,snapshot_head;reg [6:0] snapshot_filled;
reg [5:0] history_q,copy_pos_q;reg copy_valid;
wire frame_start=vs_d && !vs;
reg [15:0] magnitude;
reg [3:0] sample_valid_pipe;reg [5:0] height_q,envelope_q;
// PCM samples are separated by more than 1500 pixel clocks. Four pipeline
// clocks preserve exact sample/bin ownership while breaking the amplitude path.
always @(posedge clk or posedge rst)begin
 if(rst)begin magnitude<=0;sample_valid_pipe<=0;height_q<=0;envelope_q<=0;end
 else begin
  magnitude<=audio_left[23] ? (~audio_left[23:8]+16'd1) : audio_left[23:8];
  sample_valid_pipe<={sample_valid_pipe[2:0],audio_valid};height_q<=height;envelope_q<=next_envelope;
 end
end
wire sample_valid=sample_valid_pipe[3];
wire [31:0] magnitude_total=magnitude_sum+{16'd0,magnitude};
wire [31:0] average_height=magnitude_total >> ($clog2(SAMPLES_PER_BAR)+8);
reg [$clog2(SAMPLES_PER_BAR):0] crossings;
reg negative_phase;
reg positive_cross,negative_cross;
always @(posedge clk)begin
 positive_cross<=negative_phase && $signed(audio_left[23:8])>16'sd128;
 negative_cross<=!negative_phase && $signed(audio_left[23:8])< -16'sd128;
end
wire [23:0] crossing_total=crossings+((positive_cross || negative_cross)?24'd1:24'd0);
wire [23:0] crossing_rate=(crossing_total<<8)>>$clog2(SAMPLES_PER_BAR);
wire [4:0] activity=crossing_rate>16?5'd16:crossing_rate[4:0];
wire [4:0] weighted_activity=movie_f || average_height==0?5'd0:
 average_height>=16?{2'd0,activity[4:2]}:average_height>=8?{1'd0,activity[4:1]}:activity;
wire [31:0] target_height=average_height+{27'd0,weighted_activity};
wire [5:0] height=target_height>30?6'd30:target_height[5:0];
wire [5:0] released=envelope!=0?envelope-6'd1:6'd0;
wire [7:0] attack_sum={2'd0,envelope}+{1'd0,envelope,1'b0}+{2'd0,height_q}+8'd3;
wire [5:0] next_envelope=height_q>envelope?attack_sum[7:2]:(height_q>released?height_q:released);
// Freeze ring ownership during the 64-cycle vertical-blank snapshot. Retain
// the peak and saturated count if a sample arrives at the snapshot boundary.
wire bin_done=enabled_f && sample_valid && sample_count==SAMPLES_PER_BAR-1 && !frame_start && !copying && !copy_valid;
wire [5:0] copy_address=snapshot_head+copy_pos;
always @(posedge clk)begin
 if(!rst && bin_done)history[write_pos]<=envelope_q;
 if(copying)history_q<=history[copy_address];
 if(copy_valid)display_bars[copy_pos_q]<=({1'b0,copy_pos_q}>=7'd64-snapshot_filled)?history_q:6'd0;
end
always @(posedge clk or posedge rst)begin
 if(rst)begin
  enabled_f<=0;movie_f<=0;vs_d<=1;de_d<=0;physical_x<=0;y<=0;row_phase<=0;sample_count<=0;magnitude_sum<=0;
  write_pos<=0;envelope<=0;filled<=0;crossings<=0;negative_phase<=0;copying<=0;copy_pos<=0;
  snapshot_head<=0;snapshot_filled<=0;copy_valid<=0;copy_pos_q<=0;
 end else begin
  vs_d<=vs;de_d<=de;copy_valid<=copying;copy_pos_q<=copy_pos;
  if(!vs)begin physical_x<=0;y<=0;row_phase<=0;end
  else if(de)begin if(physical_x<1279)physical_x<=physical_x+1'b1;end
  else begin physical_x<=0;if(de_d)begin if(row_phase!=0)y<=y+1'b1;row_phase<=row_phase==2?0:row_phase+1'b1;end end
  if(!enabled_f)begin crossings<=0;negative_phase<=0;sample_count<=0;magnitude_sum<=0;crossings<=0;write_pos<=0;envelope<=0;filled<=0;end
  else if(sample_valid)begin
   if(positive_cross)negative_phase<=0;else if(negative_cross)negative_phase<=1;
   if(bin_done)begin
    sample_count<=0;magnitude_sum<=0;crossings<=0;write_pos<=write_pos+1'b1;envelope<=envelope_q;
    if(filled<64)filled<=filled+1'b1;
   end else begin
    if(sample_count<SAMPLES_PER_BAR-1)sample_count<=sample_count+1'b1;
    // During a deferred boundary retain the existing bin (do not overflow sum).
    if(sample_count<SAMPLES_PER_BAR-1)begin magnitude_sum<=magnitude_total;crossings<=crossing_total;end
   end
  end
  if(copying)begin
   if(copy_pos==63)copying<=0;else copy_pos<=copy_pos+1'b1;
  end
  if(frame_start)begin
   enabled_f<=enabled;movie_f<=movie_mode;
   snapshot_head<=write_pos;snapshot_filled<=enabled_f?filled:7'd0;
   copying<=enabled;copy_pos<=0;
  end
 end
end
reg [5:0] bar_q;
reg [23:0] rgb_q;reg hs_q,vs_q,de_q,visible_q,bar_area_q;
reg [2:0] column_q;reg [5:0] distance_q;
wire [9:0] bar_x=x-10'd64;
wire [8:0] distance=y>=380?y-9'd380:9'd379-y;
always @(posedge clk)begin
 if(enabled_f && de && x>=64 && x<576 && y>=348 && y<412)bar_q<=display_bars[bar_x[8:3]];
 rgb_q<=rgb;hs_q<=hs;vs_q<=vs;de_q<=de && !rst;
 visible_q<=enabled_f;column_q<=bar_x[2:0];distance_q<=distance[5:0];
 bar_area_q<=x>=64 && x<576 && y>=348 && y<412;
 out_hs<=hs_q;out_vs<=vs_q;out_de<=de_q;out_rgb<=rgb_q;
 // Floating white capsules with a one-pixel black outline. Every other pixel
 // retains the exact media RGB value; there is no box, fill, or colored panel.
 if(de_q && bar_area_q && visible_q)begin
  if((column_q>=1 && column_q<=6 && distance_q<=bar_q+1) ||
     (column_q>=2 && column_q<=5 && distance_q==bar_q+2))out_rgb<=24'h000000;
  if(column_q>=2 && column_q<=5 &&
    (distance_q<=bar_q || (distance_q==bar_q+1 && (column_q==3 || column_q==4))))
   out_rgb<=24'hffffff;
 end
end
endmodule
