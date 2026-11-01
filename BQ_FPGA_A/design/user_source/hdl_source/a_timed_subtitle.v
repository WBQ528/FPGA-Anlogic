// Audio-media-time based captions on A's 1280x960 canvas. No wall-clock timer.
// One line at a time, timed to spoken clauses. The bounded scan runs in blanking.
// Pause, seek and replay therefore use the same authoritative PCM clock.
module a_timed_subtitle(
 input clk,rst,hs,vs,de,input [23:0] rgb,
 input enabled,ended,input [31:0] media_ms,
 output reg out_hs,out_vs,out_de,output reg [23:0] out_rgb,
 output caption_used,output reg [4:0] cue_id
);
`include "a_subtitle_meta.vh"
reg vs_d,de_d,scan;reg [4:0] scan_id;reg [16:0] time_f;
reg [4:0] line_length;reg [10:0] x;reg [9:0] y;
wire frame_start=vs_d && !vs;
always @(posedge clk or posedge rst)begin
 if(rst)begin vs_d<=1;de_d<=0;scan<=0;scan_id<=0;time_f<=0;cue_id<=31;line_length<=0;x<=0;y<=0;end
 else begin
  vs_d<=vs;de_d<=de;
  if(!vs)begin x<=0;y<=0;end
  else if(de)begin if(x<1279)x<=x+1'b1;end
  else begin x<=0;if(de_d && y<959)y<=y+1'b1;end
  if(frame_start)begin
   time_f<=media_ms[16:0];scan_id<=0;scan<=enabled && !ended && media_ms<72000;
   cue_id<=31;line_length<=0;
  end else if(scan)begin
   if(time_f>=cue_start_ms(scan_id) && time_f<cue_end_ms(scan_id))begin
    cue_id<=scan_id;line_length<=cue_line_length(scan_id);scan<=0;
   end else if(scan_id==SUBTITLE_CUE_COUNT-1'b1)scan<=0;else scan_id<=scan_id+1'b1;
  end
 end
end
assign caption_used=cue_id!=31;
wire [10:0] left=11'd640-({6'd0,line_length}<<4)-({6'd0,line_length}<<3);
wire [10:0] width=({6'd0,line_length}<<5)+({6'd0,line_length}<<4);
wire [9:0] top=10'd856;
wire [10:0] local_x=x-left;wire [9:0] local_y=y-top;
wire visible=cue_id!=31 && de && x>=left && local_x<width && y>=top && local_y<64;
wire panel=cue_id!=31 && de && x>=32 && x<1248 && y>=844 && y<936;
reg [9:0] text_address;reg [4:0] gx_a,gy_a,gx_b,gy_b;
wire [7:0] character;reg [16:0] glyph_address;wire glyph_bit;
a_subtitle_text text(.clk(clk),.address(text_address),.character(character));
a_subtitle_font font(.clk(clk),.address(glyph_address),.pixel(glyph_bit));
reg [5:0] vpipe,ppipe,hpipe,spipe,dpipe;reg [23:0] rgb0,rgb1,rgb2,rgb3,rgb4,rgb5;
reg glyph_q;
always @(posedge clk)begin
 // Region/cell -> text ROM -> glyph address -> glyph ROM -> registered
 // glyph -> composition. The bank/bit mux no longer drives the RGB mux
 // in the same clock. All video controls and background take the same delay.
 text_address<={cue_id,5'd0}+local_x[10:4]/7'd3;
 gx_a<={local_x[10:4]%7'd3,local_x[3:1]};gy_a<=local_y[5:1];gx_b<=gx_a;gy_b<=gy_a;
 glyph_address<=({9'd0,character}<<9)+({9'd0,character}<<8)+({12'd0,gy_b}<<4)+({12'd0,gy_b}<<3)+gx_b;
 vpipe<={vpipe[4:0],visible};ppipe<={ppipe[4:0],panel};hpipe<={hpipe[4:0],hs};spipe<={spipe[4:0],vs};dpipe<={dpipe[4:0],de && !rst};
 glyph_q<=glyph_bit;
 rgb0<=rgb;rgb1<=rgb0;rgb2<=rgb1;rgb3<=rgb2;rgb4<=rgb3;rgb5<=rgb4;
 out_hs<=hpipe[5];out_vs<=spipe[5];out_de<=dpipe[5];
 out_rgb<=vpipe[5] && glyph_q ? 24'hfff9ee:ppipe[5] ? 24'h163d33:rgb5;
end
endmodule
