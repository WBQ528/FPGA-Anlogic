// FPGA pixel compositor: high contrast red path, geometric pins/callouts,
// runtime photo thumbnail. Text is drawn by the shared guide compositor.
module b_map_overlay(
 input clk,rst,hs,vs,de,input [10:0] x,input [9:0] y,input [23:0] rgb,
 input [31:0] media_ms,input [3:0] poi,input movie,paused,depth_mode,map_valid,photo_valid,
 input [1:0] photo_bank,input signed [7:0] yaw,
 output [13:0] map_address,input [7:0] map_pixel,
 output [15:0] photo_address,input [7:0] photo_pixel,
 output reg out_hs,out_vs,out_de,output reg [23:0] out_rgb
);

reg [10:0] sx;reg [9:0] sy;reg [23:0] source_rgb;reg hs0,vs0,de0;
always @(posedge clk)begin sx<=x;sy<=y;source_rgb<=rgb;hs0<=hs;vs0<=vs;de0<=de;end
function [10:0] px;input [3:0] p;begin case(p)1:px=496;2:px=587;3:px=337;4:px=469;default:px=496;endcase end endfunction
function [9:0] py;input [3:0] p;begin case(p)1:py=466;2:py=415;3:py=381;4:py=402;default:py=466;endcase end endfunction
function signed [12:0] route_x;input integer n;begin case(n)0:route_x=496;1:route_x=553;2:route_x=587;3:route_x=543;4:route_x=469;5:route_x=405;6:route_x=337;7:route_x=286;default:route_x=242;endcase end endfunction
function signed [12:0] route_y;input integer n;begin case(n)0:route_y=466;1:route_y=435;2:route_y=415;3:route_y=382;4:route_y=402;5:route_y=424;6:route_y=381;7:route_y=344;default:route_y=306;endcase end endfunction
wire [3:0] segment;wire [8:0] fraction;wire [10:0] cursor_x;wire [9:0] cursor_y;
wire [31:0] route_ms;
b_route_clock clock_select(.movie(movie),.poi(poi),.media_ms(media_ms),.route_ms(route_ms));
b_route_timeline timeline(.clk(clk),.time_ms(route_ms),.segment(segment),.fraction(fraction),.cursor_x(cursor_x),.cursor_y(cursor_y));
wire [7:0] route_outer,route_inner,route_done;
// Signed13 is exact inside each segment bounds (maximum magnitude 3590). Outside bounds arithmetic wraps and is masked.
// DDA rasterization: y-dependent row origin settles during horizontal blanking.
// Active pixels only add dy, avoiding a full line equation in every pixel cycle.
wire signed [12:0] row_y0=$signed({8'd0,y});
(* dsp_style="yes" *) reg signed [12:0] row_product0;
reg signed [12:0] row_origin0,line_cross0;reg bounds0;
always @(posedge clk)begin
 row_product0<=$signed(row_y0)*13'sd57 * -1;
 row_origin0<=row_product0+13'sd41938;
 if(x==0)line_cross0<=row_origin0;else line_cross0<=line_cross0+-13'sd31;
 bounds0<=x>=490 && x<=559 && y>=429 && y<=472;
end
assign route_outer[0]=bounds0 && line_cross0>=-13'sd440 && line_cross0<=13'sd440;
assign route_inner[0]=bounds0 && line_cross0>=-13'sd264 && line_cross0<=13'sd264;
assign route_done[0]=0<segment || (0==segment && sx<=cursor_x);

// DDA rasterization: y-dependent row origin settles during horizontal blanking.
// Active pixels only add dy, avoiding a full line equation in every pixel cycle.
wire signed [12:0] row_y1=$signed({8'd0,y});
(* dsp_style="yes" *) reg signed [12:0] row_product1;
reg signed [12:0] row_origin1,line_cross1;reg bounds1;
always @(posedge clk)begin
 row_product1<=$signed(row_y1)*13'sd34 * -1;
 row_origin1<=row_product1+13'sd25850;
 if(x==0)line_cross1<=row_origin1;else line_cross1<=line_cross1+-13'sd20;
 bounds1<=x>=547 && x<=593 && y>=409 && y<=441;
end
assign route_outer[1]=bounds1 && line_cross1>=-13'sd270 && line_cross1<=13'sd270;
assign route_inner[1]=bounds1 && line_cross1>=-13'sd162 && line_cross1<=13'sd162;
assign route_done[1]=1<segment || (1==segment && sx<=cursor_x);

// DDA rasterization: y-dependent row origin settles during horizontal blanking.
// Active pixels only add dy, avoiding a full line equation in every pixel cycle.
wire signed [12:0] row_y2=$signed({8'd0,y});
(* dsp_style="yes" *) reg signed [12:0] row_product2;
reg signed [12:0] row_origin2,line_cross2;reg bounds2;
always @(posedge clk)begin
 row_product2<=$signed(row_y2)*13'sd44;
 row_origin2<=row_product2+13'sd1111;
 if(x==0)line_cross2<=row_origin2;else line_cross2<=line_cross2+-13'sd33;
 bounds2<=x>=537 && x<=593 && y>=376 && y<=421;
end
assign route_outer[2]=bounds2 && line_cross2>=-13'sd385 && line_cross2<=13'sd385;
assign route_inner[2]=bounds2 && line_cross2>=-13'sd231 && line_cross2<=13'sd231;
assign route_done[2]=2<segment || (2==segment && sx>=cursor_x);

// DDA rasterization: y-dependent row origin settles during horizontal blanking.
// Active pixels only add dy, avoiding a full line equation in every pixel cycle.
wire signed [12:0] row_y3=$signed({8'd0,y});
(* dsp_style="yes" *) reg signed [12:0] row_product3;
reg signed [12:0] row_origin3,line_cross3;reg bounds3;
always @(posedge clk)begin
 row_product3<=$signed(row_y3)*13'sd74;
 row_origin3<=row_product3+-13'sd39128;
 if(x==0)line_cross3<=row_origin3;else line_cross3<=line_cross3+13'sd20;
 bounds3<=x>=463 && x<=549 && y>=376 && y<=408;
end
assign route_outer[3]=bounds3 && line_cross3>=-13'sd470 && line_cross3<=13'sd470;
assign route_inner[3]=bounds3 && line_cross3>=-13'sd282 && line_cross3<=13'sd282;
assign route_done[3]=3<segment || (3==segment && sx>=cursor_x);

// DDA rasterization: y-dependent row origin settles during horizontal blanking.
// Active pixels only add dy, avoiding a full line equation in every pixel cycle.
wire signed [12:0] row_y4=$signed({8'd0,y});
reg signed [12:0] row_product4,row_origin4,line_cross4;reg bounds4;
always @(posedge clk)begin
 row_product4<=(($signed(row_y4) <<< 6));
 row_origin4<=row_product4+-13'sd36046;
 if(x==0)line_cross4<=row_origin4;else line_cross4<=line_cross4+13'sd22;
 bounds4<=x>=399 && x<=475 && y>=396 && y<=430;
end
assign route_outer[4]=bounds4 && line_cross4>=-13'sd430 && line_cross4<=13'sd430;
assign route_inner[4]=bounds4 && line_cross4>=-13'sd258 && line_cross4<=13'sd258;
assign route_done[4]=4<segment || (4==segment && sx>=cursor_x);

// DDA rasterization: y-dependent row origin settles during horizontal blanking.
// Active pixels only add dy, avoiding a full line equation in every pixel cycle.
wire signed [12:0] row_y5=$signed({8'd0,y});
(* dsp_style="yes" *) reg signed [12:0] row_product5;
reg signed [12:0] row_origin5,line_cross5;reg bounds5;
always @(posedge clk)begin
 row_product5<=$signed(row_y5)*13'sd68;
 row_origin5<=row_product5+-13'sd11417;
 if(x==0)line_cross5<=row_origin5;else line_cross5<=line_cross5+-13'sd43;
 bounds5<=x>=331 && x<=411 && y>=375 && y<=430;
end
assign route_outer[5]=bounds5 && line_cross5>=-13'sd555 && line_cross5<=13'sd555;
assign route_inner[5]=bounds5 && line_cross5>=-13'sd333 && line_cross5<=13'sd333;
assign route_done[5]=5<segment || (5==segment && sx>=cursor_x);

// DDA rasterization: y-dependent row origin settles during horizontal blanking.
// Active pixels only add dy, avoiding a full line equation in every pixel cycle.
wire signed [12:0] row_y6=$signed({8'd0,y});
(* dsp_style="yes" *) reg signed [12:0] row_product6;
reg signed [12:0] row_origin6,line_cross6;reg bounds6;
always @(posedge clk)begin
 row_product6<=$signed(row_y6)*13'sd51;
 row_origin6<=row_product6+-13'sd6962;
 if(x==0)line_cross6<=row_origin6;else line_cross6<=line_cross6+-13'sd37;
 bounds6<=x>=280 && x<=343 && y>=338 && y<=387;
end
assign route_outer[6]=bounds6 && line_cross6>=-13'sd440 && line_cross6<=13'sd440;
assign route_inner[6]=bounds6 && line_cross6>=-13'sd264 && line_cross6<=13'sd264;
assign route_done[6]=6<segment || (6==segment && sx>=cursor_x);

// DDA rasterization: y-dependent row origin settles during horizontal blanking.
// Active pixels only add dy, avoiding a full line equation in every pixel cycle.
wire signed [12:0] row_y7=$signed({8'd0,y});
(* dsp_style="yes" *) reg signed [12:0] row_product7;
reg signed [12:0] row_origin7,line_cross7;reg bounds7;
always @(posedge clk)begin
 row_product7<=$signed(row_y7)*13'sd44;
 row_origin7<=row_product7+-13'sd4268;
 if(x==0)line_cross7<=row_origin7;else line_cross7<=line_cross7+-13'sd38;
 bounds7<=x>=236 && x<=292 && y>=300 && y<=350;
end
assign route_outer[7]=bounds7 && line_cross7>=-13'sd410 && line_cross7<=13'sd410;
assign route_inner[7]=bounds7 && line_cross7>=-13'sd246 && line_cross7<=13'sd246;
assign route_done[7]=7<segment || (7==segment && sx>=cursor_x);
reg signed [12:0] dx,dy;
always @(posedge clk)begin dx<=$signed({2'b0,x})-$signed({2'b0,px(poi)});dy<=$signed({3'b0,y})-$signed({3'b0,py(poi)});end
wire [25:0] radius2=dx*dx+dy*dy;
reg signed [12:0] cx,cy;
always @(posedge clk)begin cx<=$signed({2'b0,x})-$signed({2'b0,cursor_x});cy<=$signed({3'b0,y})-$signed({3'b0,cursor_y});end
wire [25:0] cursor2=cx*cx+cy*cy;
wire [5:0] pulse=media_ms[9:5];
wire [5:0] ring_radius=6'd23+(pulse<16?pulse[4:1]:5'd15-pulse[4:1]);
reg [11:0] ring_outer;
reg [11:0] ring_inner;reg [5:0] ring_r0,ring_r1;
always @(posedge clk)begin ring_r0<=ring_radius;ring_r1<=ring_radius-6'd6;ring_outer<=ring_r0*ring_r0;ring_inner<=ring_r1*ring_r1;end
wire ring=radius2>=ring_inner && radius2<=ring_outer;
wire ring_white=radius2>=ring_inner-12'd90 && radius2<=ring_outer+12'd100;
wire in_card=sx>=840 && sx<1240 && sy>=270 && sy<572;
wire card_border=in_card && (sx<845 || sx>=1235 || sy<275 || sy>=567);
wire in_photo=sx>=880 && sx<1200 && sy>=324 && sy<504;
wire [10:0] photo_dx=x-11'd880;wire [9:0] photo_dy=y-10'd324;
// floor(y*2/5) is exactly (y*205)>>9 for this bounded 0..179 pane.
wire [17:0] thumb_y_product=({8'd0,photo_dy}<<7)+({8'd0,photo_dy}<<6)+({8'd0,photo_dy}<<3)+({8'd0,photo_dy}<<2)+photo_dy;
wire [6:0] thumb_y=thumb_y_product[15:9];
wire [14:0] thumb_index=({8'd0,thumb_y}<<7)+({8'd0,thumb_y}<<5)+{5'd0,photo_dx[10:1]};
reg [15:0] photo_address_q;assign photo_address=photo_address_q;
always @(posedge clk)photo_address_q<=({14'd0,photo_bank}<<13)+({14'd0,photo_bank}<<12)+thumb_index;
// POI changes only at frame commit, well before active pixels. Precompute
// callout bounds to remove POI decode + addition + compare from one pixel path.
reg [10:0] lead_left;reg [9:0] lead_top,lead_bottom,lead_anchor;
always @(posedge clk)begin
 lead_left<=px(poi)+11'd30;lead_top<=py(poi)-10'd3;
 lead_bottom<=py(poi)+10'd3;lead_anchor<=py(poi);
end
wire lead_a=sx>=lead_left && sx<=780 && sy>=lead_top && sy<=lead_bottom;
wire lead_b=sx>=777 && sx<=783 && sy>=310 && sy<=lead_anchor;
wire lead_c=sx>=780 && sx<=840 && sy>=307 && sy<=313;
// Distinct vector start pin and chequered finish flag. They do not consume TF.
wire signed [12:0] start_dx=$signed({2'b0,sx})-13'sd496;
wire start_pin=sy>=476 && sy<502 && (start_dx<0?-start_dx:start_dx)<(13'sd502-$signed({3'b0,sy}));
wire end_pole=sx>=238 && sx<=243 && sy>=264 && sy<=311;
wire end_flag=sx>=244 && sx<=272 && sy>=265 && sy<285;
assign map_address=0;
reg hs_q,vs_q,de_q,hs2,vs2,de2;reg [23:0] base_q,source_q,thumb_q;reg photo_q,photo_select;
reg [14:0] features;reg enabled_q,flag_check;
reg [4:0] high_features;reg high_enabled,high_check;
wire [23:0] thumb_rgb={photo_pixel[7:5],photo_pixel[7:5],photo_pixel[7:6],photo_pixel[4:2],photo_pixel[4:2],photo_pixel[4:3],photo_pixel[1:0],photo_pixel[1:0],photo_pixel[1:0],photo_pixel[1:0]};
reg [23:0] composed;
always @*begin
 composed=source_q;
 if(enabled_q)begin
  if(features[0])composed=24'hfff9ee;
  if(features[1])composed=24'he53935;
  if(features[2])composed=24'hcd9590;
  if(features[3])composed=24'hc7252b;
  if(features[4])composed=24'hfffaf0;
  if(features[5])composed=24'he12932;
  if(features[6])composed=24'hffffff;
  if(features[7])composed=24'hc31225;
 end
end
// Use the existing final output register for the high-priority vector/card
// palette. Pixel latency and ordering stay unchanged, while neither stage
// contains the full thirteen-element priority chain.
reg [23:0] final_color;
always @*begin
 final_color=base_q;
 if(high_enabled)begin
  if(high_features[0])final_color=24'h17634b;
  if(high_features[1])final_color=24'h192b29;
  if(high_features[2])final_color=high_check ?24'hffffff:24'hc31225;
  if(high_features[3])final_color=24'hfff9ee;
  if(high_features[4])final_color=24'hc7252b;
 end
 if(photo_q)final_color=thumb_q;
end
always @(posedge clk)begin
 // Compute geometric membership first; colour priority is a separate stage.
 features<={2'd0,card_border,in_card,end_flag,end_pole,start_pin,movie && cursor2<=36,movie && cursor2<=100,
  ring,ring_white,lead_a || lead_b || lead_c,|(route_inner & ~route_done) && sx[4:0]<16,|(route_inner & route_done),|route_outer};
 enabled_q<=map_valid && !depth_mode;flag_check<=sx[3]^sy[3];source_q<=source_rgb;
 photo_select<=!depth_mode && map_valid && photo_valid && in_photo;
 hs2<=hs0;vs2<=vs0;de2<=de0;
 hs_q<=hs2;vs_q<=vs2;de_q<=de2;base_q<=composed;photo_q<=photo_select;thumb_q<=thumb_rgb;
 high_features<=features[12:8];high_enabled<=enabled_q;high_check<=flag_check;
 out_hs<=hs_q;out_vs<=vs_q;out_de<=de_q;out_rgb<=final_color;
end
endmodule
