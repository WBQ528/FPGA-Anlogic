// FPGA generated garden / itinerary page. Only character glyphs and ordinary
// photographs are stored. Text selection, line placement, route and QR pixels
// are evaluated at runtime from the committed scene/list snapshots.
module b_guide_overlay #(parameter RUNTIME_CAPTION=0)(
 input clk,rst,hs,vs,de,input [10:0] x,input [9:0] y,input [23:0] rgb,
 input [1:0] page,input [3:0] poi,photo_id,input free_view,paused,map_valid,input caption_banner,
 input [11:0] list_order,input [2:0] list_count,input qr_valid,
 output [10:0] qr_address,input qr_pixel,
 output [13:0] map_address,input [7:0] map_pixel,
 output reg out_hs,out_vs,out_de,output reg [23:0] out_rgb
);
wire show_header=!(RUNTIME_CAPTION!=0 && caption_banner);
reg [5:0] label;reg [10:0] ox;reg [9:0] oy;reg text_on,big,white;
wire [3:0] safe_poi=poi>=1 && poi<=4 ? poi:4'd1;
wire [1:0] photo_number=photo_id<4 ? 2'd0:photo_id[0] ? 2'd2:2'd1;
reg [1:0] entry;reg [2:0] entry_poi;integer marker;
always @*begin
 label=0;ox=0;oy=0;text_on=0;big=0;white=0;entry=0;entry_poi=0;
 // A quiet, consistent title bar. Garden photographs are unobscured in their
 // own contain-fitted pane; readable text is on a solid contrast panel.
 if(show_header && x>=32 && x<272 && y>=(page==0?648:8) && y<(page==0?712:72))begin text_on=1;big=1;white=1;ox=11'd32;oy=page==0?10'd648:10'd8;label=0;end
 else if(show_header && x>=320 && x<608 && y>=(page==0?664:24) && y<(page==0?696:56))begin text_on=1;white=1;ox=11'd320;oy=page==0?10'd664:10'd24;label=page==0 ? 1:page==1 ? 2:3;end
 else if(show_header && x>=976 && x<1192 && y>=(page==0?664:24) && y<(page==0?696:56))begin text_on=1;white=1;ox=11'd976;oy=page==0?10'd664:10'd24;label=free_view ? 14:15;end
 else if(page==0)begin
  if(x>=880 && x<1120 && y>=282 && y<314)begin text_on=1;ox=11'd880;oy=10'd282;label=3+safe_poi;end
  else if(x>=880 && x<1216 && y>=520 && y<552)begin text_on=1;ox=11'd880;oy=10'd520;label=7+safe_poi;end
  else if(paused && x>=32 && x<128 && y>=96 && y<128)begin text_on=1;ox=11'd32;oy=10'd96;label=12;end
  else if(!map_valid && x>=512 && x<704 && y>=342 && y<374)begin text_on=1;ox=11'd512;oy=10'd342;label=13;end
 end else if(page==1)begin
  white=1;
  if(x>=968 && x<1256 && y>=112 && y<176)begin text_on=1;big=1;ox=11'd968;oy=10'd112;label=3+safe_poi;end
  else if(x>=968 && x<1256 && y>=200 && y<232)begin text_on=1;ox=11'd968;oy=10'd200;label=7+safe_poi;end
  else if(x>=968 && x<1256 && y>=272 && y<400)begin
   ox=11'd968;label=30+(safe_poi-1)*3;
   if(y<304)begin text_on=1;oy=10'd272;end
   else if(y>=320 && y<352)begin text_on=1;oy=10'd320;label=label+1'b1;end
   else if(y>=368)begin text_on=1;oy=10'd368;label=label+2'd2;end
  end else if(x>=968 && x<1256 && y>=424 && y<456)begin text_on=1;ox=11'd968;oy=10'd424;label=48;end
  else if(x>=968 && x<1256 && y>=616 && y<648)begin text_on=1;ox=11'd968;oy=10'd616;label=43;end
  else if(x>=32 && x<368 && y>=668 && y<700)begin white=0;text_on=1;ox=11'd32;oy=10'd668;label=45;end
 end else if(page==2)begin
  if(x>=888 && x<1248 && y>=112 && y<144)begin text_on=1;ox=11'd888;oy=10'd112;label=18;end
  else if(x>=888 && x<1248 && y>=580 && y<612)begin text_on=1;ox=11'd888;oy=10'd580;label=19;end
  else if(x>=888 && x<1248 && y>=628 && y<660)begin text_on=1;ox=11'd888;oy=10'd628;label=44;end
  else if(list_count==0 && x>=128 && x<752 && y>=568 && y<600)begin text_on=1;ox=11'd128;oy=10'd568;label=17;end
  else if(!qr_valid && x>=984 && x<1200 && y>=352 && y<384)begin text_on=1;ox=11'd984;oy=10'd352;label=list_count==0 ? 16:20;end
  else if(x>=48 && x<816 && y>=560 && y<688)begin
   entry={y>=624,x>=432};entry_poi=list_order[entry*3+:3];
   ox=x>=432 ? 11'd432:11'd48;oy=y>=624 ? 10'd624:10'd560;
   if(entry<list_count && (x<352 || (x>=432 && x<736)))begin
    text_on=1;big=1;
    if(x<144 || (x>=432 && x<528))label=21+entry;
    else begin ox=x>=432 ? 11'd528:11'd144;label=3+entry_poi;end
   end
  end
 end
end
// Background regions are independent of text selection. Register compact
// predicates, then apply the palette alongside the existing mini-map stage.
// This removes the text-priority path from RGB without adding pixel latency.
wire dot_row=page==1 && y>=671 && y<691;
wire [2:0] dot_region={x>=496 && x<524,x>=448 && x<476,x>=400 && x<428};
wire selected_dot=(dot_region[0] && photo_number==0) ||
 (dot_region[1] && photo_number==1) || (dot_region[2] && photo_number==2);
reg [3:0] palette_a;
always @(posedge clk)begin
 palette_a[0]<=((page!=0 && y<80) || (page==0 && y>=640)) ||
  (page==1 && x>=944 && x<1264 && y>=96 && y<656);
 palette_a[1]<=(page==1 && y>=656) || (page==2 && (y>=548 || (x>=856 && y>=80)));
 palette_a[2]<=dot_row && |dot_region && !selected_dot;
 palette_a[3]<=(page==1 && x>=944 && x<1264 && y>=96 && y<100) || (dot_row && selected_dot);
end
wire in_qr=page==2 && qr_valid && x>=888 && x<1248 && y>=192 && y<552;
wire in_modules=in_qr && x>=920 && x<1216 && y>=224 && y<520;
wire in_mini=page==1 && x>=960 && x<1216 && y>=464 && y<608;
wire [7:0] mini_x=(x-11'd960)>>1;wire [6:0] mini_y=(y-10'd464)>>1;
assign map_address=in_mini ? {mini_y,mini_x[6:0]}:14'd0;
function [6:0] mini_px;input [3:0] p;begin case(p)1:mini_px=49;2:mini_px=58;3:mini_px=33;default:mini_px=46;endcase end endfunction
function [6:0] mini_py;input [3:0] p;begin case(p)1:mini_py=46;2:mini_py=41;3:mini_py=38;default:mini_py=40;endcase end endfunction
reg [6:0] mini_point_x,mini_point_y;
always @(posedge clk)begin mini_point_x<=mini_px(poi);mini_point_y<=mini_py(poi);end
wire [7:0] mini_dx=mini_x>=mini_point_x ? mini_x-mini_point_x:mini_point_x-mini_x;
wire [7:0] mini_dy=mini_y>=mini_point_y ? mini_y-mini_point_y:mini_point_y-mini_y;
wire [23:0] mini_rgb={map_pixel[7:5],map_pixel[7:5],map_pixel[7:6],map_pixel[4:2],map_pixel[4:2],map_pixel[4:3],map_pixel[1:0],map_pixel[1:0],map_pixel[1:0],map_pixel[1:0]};
wire [5:0] mx=(x-11'd920)>>3,my=(y-10'd224)>>3;
assign qr_address=in_modules ? ({5'd0,my}<<5)+({5'd0,my}<<2)+{5'd0,my}+{5'd0,mx}:11'd0;
// Nine pixel stages: layout -> offset -> cell -> text ROM -> glyph
// address -> glyph RAM -> per-bank bits -> selected bit -> final blend.
reg [5:0] label_a,label_b,label_c,index_c;
reg [10:0] x_a,ox_a,tx_b;reg [9:0] y_a,oy_a,ty_b;
reg big_a,big_b;reg [4:0] gy_c,gy_d,gx_c,gx_d;
wire [7:0] character;
b_guide_text words(.clk(clk),.label(label_c),.index(index_c),.character(character));
reg [17:0] font_address;wire glyph_pixel;reg glyph_g;
b_guide_font font(.clk(clk),.address(font_address),.pixel(glyph_pixel));
reg [10:0] marker_left[0:3],marker_right[0:3];
reg [9:0] marker_top[0:3],marker_bottom[0:3];
wire [3:0] marker_fill,marker_white;

// Vector numerals have their own short pipeline. They do not pass the four
// marker comparators through the page-layout/font-address priority network.
function numeral;input [1:0] n;input [4:0] xx,yy;reg [6:0] s;begin
 case(n)0:s=7'b0110000;1:s=7'b1101101;2:s=7'b1111001;default:s=7'b0110011;endcase
 numeral=(s[6] && xx>=7 && xx<17 && yy>=5 && yy<8) ||
  (s[5] && xx>=16 && xx<19 && yy>=7 && yy<16) ||
  (s[4] && xx>=16 && xx<19 && yy>=16 && yy<26) ||
  (s[3] && xx>=7 && xx<17 && yy>=25 && yy<28) ||
  (s[2] && xx>=5 && xx<8 && yy>=16 && yy<26) ||
  (s[1] && xx>=5 && xx<8 && yy>=7 && yy<16) ||
  (s[0] && xx>=7 && xx<17 && yy>=14 && yy<17);
end endfunction
genvar m;
generate for(m=0;m<4;m=m+1)begin:marker_geometry
 reg inside_a;reg [4:0] dx_a,dy_a;
 reg [6:0] fill_pipe,white_pipe;
 always @(posedge clk)begin
  marker_left[m]<=point_x(list_order[m*3+:3])-12'd12;
  marker_right[m]<=point_x(list_order[m*3+:3])+12'd12;
  marker_top[m]<=point_y(list_order[m*3+:3])-11'd16;
  marker_bottom[m]<=point_y(list_order[m*3+:3])+11'd16;
  inside_a<=page==2 && m<list_count && x>=marker_left[m] && x<marker_right[m] && y>=marker_top[m] && y<marker_bottom[m];
  dx_a<=x-marker_left[m];dy_a<=y-marker_top[m];
  fill_pipe<={fill_pipe[5:0],inside_a};
  white_pipe<={white_pipe[5:0],inside_a && (numeral(m,dx_a,dy_a) || dx_a==0 || dx_a==23 || dy_a==0 || dy_a==31)};
 end
 assign marker_fill[m]=fill_pipe[6];assign marker_white[m]=white_pipe[6];
end endgenerate
function signed [11:0] point_x;input [2:0] p;begin case(p)1:point_x=342;2:point_x=398;3:point_x=242;default:point_x=325;endcase end endfunction
function signed [10:0] point_y;input [2:0] p;begin case(p)1:point_y=379;2:point_y=347;3:point_y=326;default:point_y=339;endcase end endfunction
wire [2:0] line_hit;
genvar i;
generate for(i=0;i<3;i=i+1)begin:route
 // Geometry is derived from the live itinerary; registered before pixel
 // evaluation. A frame-boundary list commit occurs during vertical blanking.
 reg signed [11:0] ax,bx;reg signed [10:0] ay,by;
 reg signed [8:0] vx,vy;reg [10:0] left,right;reg [9:0] top,bottom;
 wire [8:0] abs_vx=vx[8] ? (~vx+9'd1):vx;
 wire [8:0] abs_vy=vy[8] ? (~vy+9'd1):vy;
 reg [10:0] threshold;reg enabled;
 reg signed [12:0] dx_a,dy_a;
 reg signed [15:0] product_x_b,product_y_b;
 reg signed [16:0] cross_c;reg bounded_a,bounded_b,bounded_c;
 reg hit_d,hit_e,hit_f,hit_g,hit_h;
 always @(posedge clk)begin
  ax<=point_x(list_order[i*3+:3]);bx<=point_x(list_order[(i+1)*3+:3]);
  ay<=point_y(list_order[i*3+:3]);by<=point_y(list_order[(i+1)*3+:3]);
  vx<=bx-ax;vy<=by-ay;
  left<=(ax<bx ? ax:bx)-12'd5;right<=(ax>bx ? ax:bx)+12'd5;
  top<=(ay<by ? ay:by)-11'd5;bottom<=(ay>by ? ay:by)+11'd5;
  // Explicit magnitudes prevent unsigned multiplication context from
  // zero-extending a negative 9-bit component before its negation.
  threshold<=({2'd0,abs_vx}+{2'd0,abs_vy})<<1;
  enabled<=list_count>i+1;
  dx_a<=$signed({2'b0,x})-ax;dy_a<=$signed({3'b0,y})-ay;
  bounded_a<=enabled && x>=left && x<=right && y>=top && y<=bottom;
  product_x_b<=dx_a*vy;product_y_b<=dy_a*vx;bounded_b<=bounded_a;
  cross_c<=$signed({product_x_b[15],product_x_b})-$signed({product_y_b[15],product_y_b});bounded_c<=bounded_b;
  hit_d<=bounded_c && cross_c>=-$signed({6'd0,threshold}) && cross_c<=$signed({6'd0,threshold});
  hit_e<=hit_d;hit_f<=hit_e;hit_g<=hit_f;hit_h<=hit_g;
 end
 assign line_hit[i]=hit_h;
end endgenerate
reg [23:0] base_a,base_b,base_c,base_d,base_e,base_f,base_g,base_h;
reg [7:0] text_pipe,white_pipe,qr_pipe,module_pipe,bit_pipe;
reg [7:0] hp,vp,dp,list_pipe;
reg mini_a,pin_a,pin_border_a;
always @(posedge clk)begin
 label_a<=label;x_a<=x;y_a<=y;ox_a<=ox;oy_a<=oy;big_a<=big;
 label_b<=label_a;tx_b<=x_a-ox_a;ty_b<=y_a-oy_a;big_b<=big_a;
 label_c<=label_b;index_c<=big_b ? tx_b[10:4]/7'd3:tx_b[10:3]/8'd3;
 gx_c<=big_b ? {tx_b[10:4]%7'd3,tx_b[3:1]}:{tx_b[10:3]%8'd3,tx_b[2:0]};
 gy_c<=big_b ? ty_b[5:1]:ty_b[4:0];gx_d<=gx_c;gy_d<=gy_c;
 font_address<={character,gy_d,gx_d};glyph_g<=glyph_pixel;
 text_pipe<={text_pipe[6:0],text_on};white_pipe<={white_pipe[6:0],white};
 mini_a<=in_mini;pin_a<=mini_dx+mini_dy<=4;pin_border_a<=mini_dx+mini_dy<=6;
 base_a<=rgb;
 base_b<=mini_a ? (pin_a ? 24'hc7252b:pin_border_a ? 24'hffffff:mini_rgb):
  palette_a[3] ? 24'hc7252b:palette_a[2] ? 24'hbac9bd:
  palette_a[1] ? 24'hf3f5e9:palette_a[0] ? 24'h143f34:base_a;
 base_c<=base_b;base_d<=base_c;base_e<=base_d;base_f<=base_e;base_g<=base_f;base_h<=base_g;
 qr_pipe<={qr_pipe[6:0],in_qr};module_pipe<={module_pipe[6:0],in_modules};
 bit_pipe<={bit_pipe[6:0],qr_pixel};list_pipe<={list_pipe[6:0],page==2};
 hp<={hp[6:0],hs};vp<={vp[6:0],vs};dp<={dp[6:0],de};
 out_hs<=hp[7];out_vs<=vp[7];out_de<=dp[7];
 out_rgb<=text_pipe[7] && glyph_g ? (white_pipe[7] ? 24'hfff9ee:24'h153c31):
   qr_pipe[7] ? (module_pipe[7] && bit_pipe[6] ? 24'h000000:24'hffffff):
   |marker_white ? 24'hffffff:|marker_fill ? 24'hc7252b:
   list_pipe[7] && |line_hit ? 24'hc7252b:base_h;
end
endmodule
