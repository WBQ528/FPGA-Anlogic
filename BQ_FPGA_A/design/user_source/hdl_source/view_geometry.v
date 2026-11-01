// R5 full 1280x960 viewport; native BMP aspect restored from header.
// Geometry setup runs in vertical blank; cache is normalized 1280x960 RGB565.
// Native aspect restores source proportions; movies occupy the full viewport.
// fit: 0 contain, 1 cover (center crop), 2 stretch. zoom: 0..4 = 50..150%.
// Coordinates are signed to support intentional crop outside the fixed viewport.
module view_geometry(
 input clk,rst,start,input movie,input [10:0] native_width,native_height,
 input [1:0] fit,input [2:0] zoom,input [9:0] flip_height,
 output reg ready,output reg signed [12:0] left,top,
 output reg [11:0] width,height,output reg [23:0] step_x,step_y,
 output reg [9:0] source_top,output reg [12:0] normal_bottom
);
reg [3:0] state;reg [10:0] nw,nh;reg [2:0] zoom_f;reg movie_f,fit_width;
reg [9:0] flip_f;reg [11:0] base_w,base_h;reg [1:0] fit_f;
reg div_start;reg [23:0] numerator;reg [15:0] denominator;
wire div_busy,div_done,div_error;wire [23:0] quotient;
reg [20:0] w720,h1280;
always @(posedge clk)begin
 w720<=({10'd0,nw}<<10)-({10'd0,nw}<<6);
 h1280<=({10'd0,nh}<<10)+({10'd0,nh}<<8);
end
wire wider=(w720>=h1280);
function [15:0] zoom_scale;input [11:0] v;input [2:0] z;reg [15:0] a;begin
 a={4'd0,v};case(z)
 0:zoom_scale=a<<1;1:zoom_scale=(a<<1)+a;2:zoom_scale=a<<2;
 3:zoom_scale=(a<<2)+a;default:zoom_scale=(a<<2)+(a<<1);
 endcase end endfunction
wire [15:0] scaled_w=zoom_scale(base_w,zoom_f),scaled_h=zoom_scale(base_h,zoom_f);
reg [25:0] flipped_h,mul_term;reg [9:0] mul_bits;reg [3:0] mul_count;
serial_divide divider(.clk(clk),.rst(rst),.start(div_start),.numerator(numerator),
 .denominator(denominator),.busy(div_busy),.done(div_done),.error(div_error),.quotient(quotient));
always @(posedge clk or posedge rst)begin
 if(rst)begin
  state<=0;ready<=0;left<=0;top<=24;width<=640;height<=400;step_x<=4096;step_y<=4915;source_top<=0;
  nw<=640;nh<=480;zoom_f<=2;movie_f<=0;fit_width<=1;flip_f<=512;base_w<=640;base_h<=400;normal_bottom<=424;fit_f<=0;
  div_start<=0;numerator<=0;denominator<=1;flipped_h<=0;mul_term<=0;mul_bits<=0;mul_count<=0;
 end else begin
  div_start<=0;
  case(state)
   0:if(start)begin
    ready<=0;movie_f<=movie;source_top<=0;
    nw<=movie?11'd1280:(native_width==0?11'd640:native_width);
    nh<=movie?11'd960:(native_height==0?11'd480:native_height);
    zoom_f<=zoom>4?3'd4:zoom;flip_f<=flip_height>512?10'd512:flip_height;
    fit_f<=fit;state<=10;
   end
   10:state<=11; // Wait for products of the captured dimensions.
   11:begin
    fit_width<=fit_f==1?!wider:wider;
    if(fit_f==2)begin base_w<=1280;base_h<=960;state<=3;end else state<=1;
   end
   1:begin
    numerator<=fit_width?(({13'd0,nh}<<10)+({13'd0,nh}<<8)):
     (({13'd0,nw}<<10)-({13'd0,nw}<<6));
    denominator<=fit_width?{5'd0,nw}:{5'd0,nh};div_start<=1;state<=2;
   end
   2:if(div_done)begin
    base_w<=fit_width?12'd1280:(quotient>2048?12'd2048:quotient[11:0]);
    base_h<=fit_width?(quotient>2048?12'd2048:quotient[11:0]):12'd960;
    state<=3;
   end
   3:begin
    normal_bottom<=13'd480+scaled_h[15:3];
    width<=scaled_w[15:2]<4?12'd4:scaled_w[13:2];
    flipped_h<=0;mul_term<={10'd0,scaled_h};mul_bits<=flip_f;mul_count<=0;state<=8;
   end
   8:begin
    if(mul_bits[0])flipped_h<=flipped_h+mul_term;
    mul_term<=mul_term<<1;mul_bits<=mul_bits>>1;mul_count<=mul_count+1'b1;
    if(mul_count==9)state<=9;
   end
   9:begin height<=flipped_h[25:11]<2?12'd2:flipped_h[22:11];state<=4;end
   4:begin
    left<=13'sd640-$signed({2'd0,width[11:1]});
    top<=13'sd480-$signed({2'd0,height[11:1]});
    numerator<=24'd5242880;denominator<={4'd0,width};div_start<=1;state<=5;
   end
   5:if(div_done)begin step_x<=quotient;state<=6;end
   6:begin numerator<=24'd3932160;denominator<={4'd0,height};div_start<=1;state<=7;end
   7:if(div_done)begin step_y<=quotient;ready<=1;state<=0;end
   default:state<=0;
  endcase
 end
end
endmodule
