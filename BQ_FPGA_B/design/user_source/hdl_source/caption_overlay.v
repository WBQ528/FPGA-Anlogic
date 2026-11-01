// R3 immutable local Source Han Sans caption ROM; two-cycle pixel pipeline.
// 2 bits/pixel: transparent, black, gray, white. No UART or upload RAM.
module caption_overlay(
 input clk,rst,hs,vs,de,input [23:0] rgb,input [8:0] caption_y,
 output caption_used,
 input enabled,scrolling,input [5:0] speed,
 output reg out_hs,out_vs,out_de,output reg [23:0] out_rgb
);
reg [7:0] default_rom[0:2047];
`include "caption_default.vh"
initial begin
`ifdef UI_FONT_SIM
 $readmemh("caption_default_rom.mem",default_rom);
`else
 $readmemh("../../td_project/caption_default_rom.mem",default_rom);
`endif
end
wire [10:0] width=DEFAULT_WIDTH;wire [5:0] height=DEFAULT_HEIGHT;
reg vs_d,de_d,enabled_f,scrolling_f;reg [10:0] physical_x;wire [9:0] x=physical_x[10:1];reg [1:0] row_phase;reg [8:0] y,y_f;
reg signed [12:0] origin;reg [1:0] fraction;
wire frame_start=vs_d && !vs;
wire [6:0] advance={5'd0,fraction}+{1'b0,speed};
assign caption_used=enabled;
always @(posedge clk or posedge rst)begin
 if(rst)begin
  vs_d<=1;de_d<=0;enabled_f<=0;scrolling_f<=0;physical_x<=0;y<=0;row_phase<=0;y_f<=432;origin<=320-(DEFAULT_WIDTH/2);fraction<=0;
 end else begin
  vs_d<=vs;de_d<=de;
  if(!de && y==0)y_f<=caption_y;
  if(!vs)begin physical_x<=0;y<=0;row_phase<=0;end
  else if(de)begin if(physical_x<1279)physical_x<=physical_x+1'b1;end
  else begin physical_x<=0;if(de_d)begin if(row_phase!=0)y<=y+1'b1;row_phase<=row_phase==2?0:row_phase+1'b1;end end
  if(frame_start)begin
   enabled_f<=enabled;scrolling_f<=scrolling;
   if(scrolling!=scrolling_f)begin
    origin<=13'sd320-$signed({3'd0,width[10:1]});fraction<=0;
   end else if(enabled && scrolling)begin
    fraction<=advance[1:0];
    if(origin<=-$signed({2'd0,width}))origin<=640;
    else origin<=origin-$signed({8'd0,advance[6:2]});
   end
  end
 end
end
wire signed [12:0] local_x=$signed({3'd0,x})-origin;
wire [8:0] local_y=y-y_f;
wire visible= enabled_f && de && local_x>=0 && local_x<$signed({2'd0,width}) && y>=y_f && local_y<height;
// Row-major byte address, constant row stride for this immutable caption.
wire [13:0] byte_index=local_y*{3'd0,width[10:2]}+{3'd0,local_x[12:2]};
reg [7:0] byte_q;reg [1:0] shift_q;reg visible_q,hs_q,vs_q,de_q;reg [23:0] rgb_q;
always @(posedge clk)begin
 if(visible)byte_q<=default_rom[byte_index[10:0]];
 shift_q<=local_x[1:0];visible_q<=visible;hs_q<=hs;vs_q<=vs;de_q<=de && !rst;rgb_q<=rgb;
 out_hs<=hs_q;out_vs<=vs_q;out_de<=de_q;out_rgb<=rgb_q;
 if(visible_q)case((byte_q >> {shift_q,1'b0}) & 8'd3)
  1:out_rgb<=24'h000000;2:out_rgb<=24'hbcbcbc;3:out_rgb<=24'hffffff;default:out_rgb<=rgb_q;
 endcase
end
endmodule
