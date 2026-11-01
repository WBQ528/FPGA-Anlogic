// E4: RGB888 full-rate two-cycle pipe, contrast around 128 then brightness.
// brightness -4..4 means -64..64 levels; contrast 0..4 => .5/.75/1/1.25/1.5.
// Signed arithmetic and saturation; parameters latch only in vertical blank.
module picture_adjust(
 input clk,rst,input hs,vs,de,input [23:0] rgb,
 input signed [3:0] brightness,input [2:0] contrast,
 input [4:0] fade,
 output reg out_hs,out_vs,out_de,output reg [23:0] out_rgb
);
reg vs_d;reg signed [3:0] bright_f;reg [2:0] contrast_f;
reg [23:0] rgb_in;reg hs_in,vs_in,de_in;reg [4:0] fade_in;
reg hs0,vs0,de0;
reg signed [12:0] r0,g0,b0;
reg [4:0] fade0;
function [7:0] dim;
 input [7:0] value;input [4:0] level;reg [12:0] product;
 begin product=value*level;dim=product[11:4];end
endfunction
function signed [12:0] adjust;
 input [7:0] value;input signed [3:0] bright;input [2:0] gain;
 reg signed [12:0] centered,scaled,offset;
 begin
  centered=$signed({1'b0,value})-13'sd128;
  case(gain)
   0:scaled=centered>>>1;
   1:scaled=(centered+(centered<<<1))>>>2;
   3:scaled=((centered<<<2)+centered)>>>2;
   4:scaled=(centered+(centered<<<1))>>>1;
   default:scaled=centered;
  endcase
  offset={{9{bright[3]}},bright};
  adjust=scaled+13'sd128+(offset<<<4);
 end
endfunction
function [7:0] clamp;
 input signed [12:0] value;
 begin clamp=value<0?8'd0:value>255?8'd255:value[7:0];end
endfunction
always @(posedge clk or posedge rst)begin
 if(rst)begin
  vs_d<=1;bright_f<=0;contrast_f<=2;hs0<=1;vs0<=1;de0<=0;
  r0<=0;g0<=0;b0<=0;fade0<=16;out_hs<=1;out_vs<=1;out_de<=0;out_rgb<=0;
  rgb_in<=0;hs_in<=1;vs_in<=1;de_in<=0;fade_in<=16;
 end else begin
  vs_d<=vs;
  if(vs_d && !vs)begin bright_f<=brightness;contrast_f<=contrast;end
  rgb_in<=rgb;hs_in<=hs;vs_in<=vs;de_in<=de;fade_in<=fade;
  hs0<=hs_in;vs0<=vs_in;de0<=de_in;
  fade0<=fade_in;
  r0<=adjust(rgb_in[23:16],bright_f,contrast_f);
  g0<=adjust(rgb_in[15:8],bright_f,contrast_f);
  b0<=adjust(rgb_in[7:0],bright_f,contrast_f);
  out_hs<=hs0;out_vs<=vs0;out_de<=de0;
  out_rgb<={dim(clamp(r0),fade0),dim(clamp(g0),fade0),dim(clamp(b0),fade0)};
 end
end
endmodule
