// R3: same transparent white capsule style for photos AND movies.
// 2.731s PCM history, smoothed attack/release. Photo mode adds a bounded,
// level-weighted zero-crossing activity term so equal-level tones can differ;
// music remains driven only by real PCM, never image ID or a generated pattern.
// Snapshot during vertical blank. Three-clock RGB/sync pipeline; disabled is idle.
module audio_wave_overlay #(parameter SAMPLES_PER_BAR=2048)(
 input clk,rst,hs,vs,de,input [23:0] rgb,
 input enabled,movie_mode,audio_valid,input [23:0] audio_left,
 output reg out_hs,out_vs,out_de,output reg [23:0] out_rgb
);
// Two logical 64-entry banks share one dedicated dual-port EMB.

// N signed-16-bit magnitudes fit in 16+ceil(log2(N)) bits, including the last sample.
localparam MAG_BITS=16+$clog2(SAMPLES_PER_BAR);
reg [$clog2(SAMPLES_PER_BAR)-1:0] sample_count;reg [MAG_BITS-1:0] magnitude_sum;
reg [5:0] write_pos,envelope;reg [6:0] filled;
reg enabled_f,movie_f,vs_d,de_d;reg [10:0] physical_x;wire [9:0] x=physical_x[10:1];reg [1:0] row_phase;reg [8:0] y;
reg copying;reg [5:0] copy_pos,snapshot_head;reg [6:0] snapshot_filled;
wire [5:0] history_q;reg [5:0] copy_pos_q;reg copy_valid;
wire frame_start=vs_d && !vs;
reg [15:0] magnitude;
reg [4:0] sample_valid_pipe;reg [5:0] height_q,envelope_q;
// PCM samples are separated by more than 1500 pixel clocks. Four pipeline
// clocks preserve exact sample/bin ownership while breaking the amplitude path.
wire sample_valid=sample_valid_pipe[4];
wire [MAG_BITS-1:0] magnitude_total=magnitude_sum+magnitude;
reg [7:0] average_height;
always @(posedge clk)average_height<=magnitude_total >> ($clog2(SAMPLES_PER_BAR)+8);
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
wire [8:0] target_height={1'b0,average_height}+{4'd0,weighted_activity};
wire [5:0] height=target_height>30?6'd30:target_height[5:0];
wire [5:0] released=envelope!=0?envelope-6'd1:6'd0;
wire [7:0] attack_sum={2'd0,envelope}+{1'd0,envelope,1'b0}+{2'd0,height_q}+8'd3;
wire [5:0] next_envelope=height_q>envelope?attack_sum[7:2]:(height_q>released?height_q:released);
always @(posedge clk or posedge rst)begin
 if(rst)begin magnitude<=0;sample_valid_pipe<=0;height_q<=0;envelope_q<=0;end
 else begin
  magnitude<=audio_left[23] ? (~audio_left[23:8]+16'd1) : audio_left[23:8];
  sample_valid_pipe<={sample_valid_pipe[3:0],audio_valid};height_q<=height;envelope_q<=next_envelope;
 end
end
// Freeze ring ownership during the 64-cycle vertical-blank snapshot. Retain
// the peak and saturated count if a sample arrives at the snapshot boundary.
wire bin_done=enabled_f && sample_valid && sample_count==SAMPLES_PER_BAR-1 && !frame_start && !copying && !copy_valid;
wire [5:0] copy_address=snapshot_head+copy_pos;
wire [5:0] bar_q;
wire [9:0] bar_x=x-10'd64;
// Port A owns history; port B owns display. Fixed address bit 6 separates
// all writes. bin_done excludes copy reads, and display writes happen only
// at frame-start, before the waveform's y=348..411 visible window.
wire wave_history_we=!rst && bin_done;
wire wave_bar_read=enabled_f && de && x>=64 && x<576 && y>=348 && y<412;
bq_wave_ram wave_memory(.clk(clk),
 .ena(wave_history_we || copying),.wea(wave_history_we),
 .aa({1'b0,wave_history_we?write_pos:copy_address}),.da(envelope_q),.qa(history_q),
 .enb(copy_valid || wave_bar_read),.web(copy_valid),
 .ab({1'b1,copy_valid?copy_pos_q:bar_x[8:3]}),
 .db(({1'b0,copy_pos_q}>=7'd64-snapshot_filled)?history_q:6'd0),.qb(bar_q));
always @(posedge clk or posedge rst)begin
 if(rst)begin
  enabled_f<=0;movie_f<=0;vs_d<=1;de_d<=0;physical_x<=0;y<=0;row_phase<=0;sample_count<=0;magnitude_sum<=0;
  write_pos<=0;envelope<=0;filled<=0;crossings<=0;negative_phase<=0;copying<=0;copy_pos<=0;
  snapshot_head<=0;snapshot_filled<=0;copy_valid<=0;copy_pos_q<=0;
 end else begin
  vs_d<=vs;de_d<=de;copy_valid<=copying;copy_pos_q<=copy_pos;
  if(!vs)begin physical_x<=0;y<=0;row_phase<=0;end
  else if(de)begin if(physical_x<1279)physical_x<=physical_x+1'b1;end
  else begin physical_x<=0;if(de_d)begin if(row_phase==1)y<=y+1'b1;row_phase<=row_phase==1?0:row_phase+1'b1;end end
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
reg [23:0] rgb_q;reg hs_q,vs_q,de_q,visible_q,bar_area_q;
reg [2:0] column_q;reg [5:0] distance_q;
reg [23:0] rgb_q2;reg hs_q2,vs_q2,de_q2,visible_q2,bar_area_q2;
reg [2:0] column_q2;reg [5:0] distance_q2,bar_q2;
wire [8:0] distance=y>=380?y-9'd380:9'd379-y;
always @(posedge clk)begin
 rgb_q<=rgb;hs_q<=hs;vs_q<=vs;de_q<=de && !rst;
 visible_q<=enabled_f;column_q<=bar_x[2:0];distance_q<=distance[5:0];
 bar_area_q<=x>=64 && x<576 && y>=348 && y<412;
 rgb_q2<=rgb_q;hs_q2<=hs_q;vs_q2<=vs_q;de_q2<=de_q;
 visible_q2<=visible_q;bar_area_q2<=bar_area_q;column_q2<=column_q;distance_q2<=distance_q;bar_q2<=bar_q;
 out_hs<=hs_q2;out_vs<=vs_q2;out_de<=de_q2;out_rgb<=rgb_q2;
 // Floating white capsules with a one-pixel black outline. Every other pixel
 // retains the exact media RGB value; there is no box, fill, or colored panel.
 if(de_q2 && bar_area_q2 && visible_q2)begin
  if((column_q2>=1 && column_q2<=6 && distance_q2<=bar_q2+1) ||
     (column_q2>=2 && column_q2<=5 && distance_q2==bar_q2+2))out_rgb<=24'h000000;
  if(column_q2>=2 && column_q2<=5 &&
    (distance_q2<=bar_q2 || (distance_q2==bar_q2+1 && (column_q2==3 || column_q2==4))))
   out_rgb<=24'hffffff;
 end
end
endmodule

// One physical 9-Kbit dual-port EMB; one cycle read, no extra output register.
// NORMAL holds the read output during writes. Different bank bits guarantee
// no same-address dual-port collision. No initial RAM contents are required:
// snapshot_filled masks invalid history, and the first snapshot fills display.
module bq_wave_ram(input clk,ena,wea,input[6:0]aa,input[5:0]da,output[5:0]qa,
 input enb,web,input[6:0]ab,input[5:0]db,output[5:0]qb);
`ifdef UI_FONT_SIM
 reg[5:0]ram[0:127];reg[5:0]read_a,read_b;
 always@(posedge clk)if(ena)begin if(wea)ram[aa]<=da;else read_a<=ram[aa];end
 always@(posedge clk)if(enb)begin if(web)ram[ab]<=db;else read_b<=ram[ab];end
 assign qa=read_a;assign qb=read_b;
`else
 wire[8:0]outa,outb;
 EG_PHY_BRAM #(.MODE("DP8K"),.DATA_WIDTH_A("9"),.DATA_WIDTH_B("9"),
 .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),
 .CSA0("1"),.CSA1("1"),.CSA2("1"),.CSB0("1"),.CSB1("1"),.CSB2("1")) ram(
 .dia({3'd0,da}),.dib({3'd0,db}),.doa(outa),.dob(outb),
 .addra({3'd0,aa,3'b111}),.addrb({3'd0,ab,3'b111}),.csa(3'b111),.csb(3'b111),
 .cea(ena),.ceb(enb),.wea(wea),.web(web),.clka(clk),.clkb(clk),
 .rsta(1'b0),.rstb(1'b0),.ocea(1'b1),.oceb(1'b1));
 assign qa=outa[5:0];assign qb=outb[5:0];
`endif
endmodule
