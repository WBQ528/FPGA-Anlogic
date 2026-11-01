// Two-cycle overlay, integer-only row-address generation. The backing cache
// changes only at a video frame boundary. Natural-width 32px glyphs; no scaling
// or video/audio buffers are touched. Empty text makes the overlay transparent.
module bq_caption_overlay #(
 parameter integer WIDTH=1280,HEIGHT=720,BASE_Y=676,DYNAMIC_Y=0
)(
 input clk,rst,hs,vs,de,input [23:0] rgb,
 input enabled,scrolling,paused,input [5:0] speed,
 input [5:0] char_count,input [15:0] epoch,
 input [9:0] position_y,
 output frame_start,output [9:0] row_address,input [31:0] row_bits,
 output reg out_hs,out_vs,out_de,output reg [23:0] out_rgb
);
 reg vs_d,de_d,frame_start_d;reg [10:0] x;reg [9:0] y;
 reg signed [12:0] origin;
 reg [1:0] fraction;reg scrolling_f,enabled_f;reg [15:0] epoch_f;
 wire [10:0] text_width={char_count,5'd0};
 assign frame_start=vs_d && !vs;
 wire [6:0] advance={5'd0,fraction}+{1'b0,speed};
 always @(posedge clk or posedge rst)begin
  if(rst)begin vs_d<=1;de_d<=0;frame_start_d<=0;x<=0;y<=0;origin<=0;fraction<=0;scrolling_f<=0;enabled_f<=0;epoch_f<=0;end
  else begin
   vs_d<=vs;de_d<=de;frame_start_d<=frame_start;
   if(!vs)begin x<=0;y<=0;end
   else if(de)begin if(x<WIDTH-1)x<=x+1'b1;end
   else begin x<=0;if(de_d)y<=y+1'b1;end
   // The endpoint commits at frame_start. Sample its new settings one clock
   // later, still in vertical blank, rather than showing the old state for a
   // whole additional frame after GET has already reported it as applied.
   if(frame_start_d)begin
    enabled_f<=enabled;scrolling_f<=scrolling;
    if(scrolling_f!=scrolling)begin
     origin<=$signed(WIDTH/2)-$signed({3'd0,text_width[10:1]});fraction<=0;
    end else if(enabled && scrolling && !paused && char_count!=0)begin
     fraction<=advance[1:0];
     if(origin<=-$signed({2'd0,text_width}))origin<=WIDTH;
     else origin<=origin-$signed({8'd0,advance[6:2]});
    end
   end
   // Cache metadata changes only in vertical blank. Recenter immediately
   // after its commit so the first visible line already uses the new width.
   if(epoch_f!=epoch)begin epoch_f<=epoch;origin<=$signed(WIDTH/2)-$signed({3'd0,text_width[10:1]});fraction<=0;end
  end
 end
 wire signed [12:0] lx=$signed({2'd0,x})-origin;
 wire [9:0] base_y=DYNAMIC_Y!=0?position_y:BASE_Y;
 wire [9:0] ly=y-base_y;
 assign row_address={lx[9:5],ly[4:0]};
 wire ink_area=enabled_f && char_count!=0 && de && y>=base_y && ly<32 && lx>=0 && lx<$signed({2'd0,text_width});
 wire bar=enabled_f && char_count!=0 && de && y>=base_y-10'd6 && y<base_y+10'd38;
 reg hs_q,vs_q,de_q,inside_q,bar_q;reg [23:0] rgb_q;reg [4:0] bit_q;
 always @(posedge clk)begin
  hs_q<=hs;vs_q<=vs;de_q<=de && !rst;rgb_q<=rgb;inside_q<=ink_area;bar_q<=bar;bit_q<=lx[4:0];
  out_hs<=hs_q;out_vs<=vs_q;out_de<=de_q;out_rgb<=rgb_q;
  if(bar_q)out_rgb<={2'd0,rgb_q[23:18],2'd0,rgb_q[15:10],2'd0,rgb_q[7:2]};
  if(inside_q && row_bits[31-bit_q])out_rgb<=24'hffffff;
 end
endmodule
