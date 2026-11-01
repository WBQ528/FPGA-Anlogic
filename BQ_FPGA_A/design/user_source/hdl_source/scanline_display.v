// R2 compositor: source scaling, two-image transitions and continuous raster.
// Geometry is calculated in blanking; memory prefetches one line ahead.
// A missed deadline produces background and a sticky count, never stale pixels.
module scanline_display(
 input mem_clk,pixel_clk,rst_mem,rst_pixel,
 input init_done,refresh,busy,writer_busy,read_valid,input [31:0] read_data,
 output read_enable,output [20:0] read_address,output reader_busy,
 input hs,vs,de,input valid,movie,input [1:0] bank_a,bank_b,
 input [10:0] native_wa,native_ha,native_wb,native_hb,
 input [1:0] fit,effect,input [2:0] zoom,input transition,input [5:0] progress,
 output reg out_hs,out_vs,out_de,output reg [23:0] out_rgb,
 output reg [15:0] underruns,output [8:0] caption_y,
 output reg content_valid
);
reg vs_d,de_d;reg [10:0] x;reg [9:0] y;
wire frame_start=vs_d && !vs;
reg [3:0] start_pipe;
reg [1:0] ba,bb,fx;reg active,trans;
reg frame_movie;reg [1:0] frame_fit;reg [2:0] frame_zoom;
reg [10:0] frame_wa,frame_ha,frame_wb,frame_hb;
reg [5:0] phase;
reg [9:0] flip_factor;
// |cos(pi*t)|, Q9. Configuration LUT rather than per-pixel trigonometry.
function [9:0] flip_cos;input [5:0] p;reg [4:0] t;begin
 t=p>16?32-p:p;
 case(t)
 0:flip_cos=512;1:flip_cos=510;2:flip_cos=502;3:flip_cos=490;
 4:flip_cos=473;5:flip_cos=452;6:flip_cos=426;7:flip_cos=396;
 8:flip_cos=362;9:flip_cos=325;10:flip_cos=284;11:flip_cos=241;
 12:flip_cos=196;13:flip_cos=149;14:flip_cos=100;15:flip_cos=50;
 default:flip_cos=0;
 endcase end endfunction
// Geometry for both immutable frame sources shares one blanking-time engine.
// Each calculation is <110 clocks; both finish well inside vertical blank.
wire ga,gb;reg geometry_ready;reg [2:0] geometry_state;
reg geometry_start,geometry_select;
reg signed [12:0] la,ta,lb,tb;
reg [11:0] wa,ha,wb,hb;reg [23:0] sxa,sya,sxb,syb;reg [9:0] sta,stb;
reg [12:0] media_bottom;
wire calculated;wire signed [12:0] calc_left,calc_top;
wire [11:0] calc_width,calc_height;wire [23:0] calc_sx,calc_sy;
wire [9:0] calc_source;wire [12:0] calc_bottom;
assign ga=geometry_ready;assign gb=geometry_ready;
assign caption_y=9'd432;
// Inputs have settled for several blanking clocks before geometry_start.
// Register the bank/metadata mux independently of the geometry capture mux.
reg [10:0] selected_native_width,selected_native_height;
always @(posedge pixel_clk)begin
 selected_native_width<=geometry_select?frame_wb:frame_wa;
 selected_native_height<=geometry_select?frame_hb:frame_ha;
end
view_geometry geometry(.clk(pixel_clk),.rst(rst_pixel),.start(geometry_start),.movie(frame_movie),
 .native_width(selected_native_width),.native_height(selected_native_height),
 .fit(frame_fit),.zoom(frame_zoom),.flip_height(flip_factor),.ready(calculated),.left(calc_left),.top(calc_top),
 .width(calc_width),.height(calc_height),.step_x(calc_sx),.step_y(calc_sy),.source_top(calc_source),.normal_bottom(calc_bottom));
always @(posedge pixel_clk or posedge rst_pixel)begin
 if(rst_pixel)begin
  geometry_ready<=0;geometry_state<=0;geometry_start<=0;geometry_select<=0;
  la<=0;ta<=48;lb<=0;tb<=48;wa<=640;ha<=376;wb<=640;hb<=376;
  sxa<=4096;sya<=4096;sxb<=4096;syb<=4096;sta<=0;stb<=0;media_bottom<=424;
 end else begin
  geometry_start<=0;
  case(geometry_state)
   0:if(start_pipe[3])begin geometry_ready<=0;geometry_select<=0;geometry_start<=1;geometry_state<=1;end
   1:geometry_state<=2; // Engine accepts start and clears its previous ready.
   2:if(calculated)begin
    la<=calc_left;ta<=calc_top;wa<=calc_width;ha<=calc_height;sxa<=calc_sx;sya<=calc_sy;sta<=calc_source;media_bottom<=calc_bottom;
    geometry_select<=1;geometry_state<=5;
   end
   5:begin geometry_start<=1;geometry_state<=3;end
   3:geometry_state<=4;
   4:if(calculated)begin
    lb<=calc_left;tb<=calc_top;wb<=calc_width;hb<=calc_height;sxb<=calc_sx;syb<=calc_sy;stb<=calc_source;
    geometry_ready<=1;geometry_state<=0;
   end
   default:geometry_state<=0;
  endcase
 end
end
reg [9:0] fetch_y,requested_y,tag0,tag1;reg [3:0] fetch_settle;
reg [7:0] epoch,requested_epoch;
reg pending,request,outstanding,seen_busy,first_line,boot_second;
reg [1:0] line_valid,line_blank;
wire ready,completed_slot;
wire signed [12:0] dya=$signed({3'd0,fetch_y})-ta,dyb=$signed({3'd0,fetch_y})-tb;
wire [36:0] ya_product=$unsigned(dya)*sya,yb_product=$unsigned(dyb)*syb;
wire [9:0] source_ya=dya<0?10'd0:ya_product[36:12]>959?10'd959:ya_product[21:12];
wire [9:0] source_yb=dyb<0?10'd0:yb_product[36:12]>959?10'd959:yb_product[21:12];
// Smoothstep easing stored once per frame; no per-pixel division.
function [9:0] conveyor_ease;input [5:0] p;begin case(p)
 0:conveyor_ease=10'd0;
 1:conveyor_ease=10'd2;
 2:conveyor_ease=10'd7;
 3:conveyor_ease=10'd16;
 4:conveyor_ease=10'd28;
 5:conveyor_ease=10'd42;
 6:conveyor_ease=10'd59;
 7:conveyor_ease=10'd78;
 8:conveyor_ease=10'd100;
 9:conveyor_ease=10'd123;
 10:conveyor_ease=10'd148;
 11:conveyor_ease=10'd175;
 12:conveyor_ease=10'd202;
 13:conveyor_ease=10'd231;
 14:conveyor_ease=10'd260;
 15:conveyor_ease=10'd290;
 16:conveyor_ease=10'd320;
 17:conveyor_ease=10'd350;
 18:conveyor_ease=10'd380;
 19:conveyor_ease=10'd409;
 20:conveyor_ease=10'd438;
 21:conveyor_ease=10'd465;
 22:conveyor_ease=10'd492;
 23:conveyor_ease=10'd517;
 24:conveyor_ease=10'd540;
 25:conveyor_ease=10'd562;
 26:conveyor_ease=10'd581;
 27:conveyor_ease=10'd598;
 28:conveyor_ease=10'd612;
 29:conveyor_ease=10'd624;
 30:conveyor_ease=10'd633;
 31:conveyor_ease=10'd638;
 32:conveyor_ease=10'd640;
 default:conveyor_ease=640;endcase end endfunction
// Row-constant source selection keeps one SDRAM line read per output row.
reg [12:0] displacement;
reg signed [12:0] old_top,new_top;
always @(posedge pixel_clk)begin
 displacement<=({3'd0,conveyor_ease(phase)}*13'd3)>>1;
 old_top<=ta-((trans && fx==1)?$signed(displacement):13'sd0);
 new_top<=tb+((trans && fx==1)?13'sd960-$signed(displacement):13'sd0);
end
reg signed [12:0] fya,fyb;
reg [36:0] fpa,fpb;reg neg_a,neg_b;
reg [9:0] row_a,row_b;
always @(posedge pixel_clk)begin
 fya<=$signed({3'd0,fetch_y})-old_top;fyb<=$signed({3'd0,fetch_y})-new_top;
 fpa<=$unsigned(fya)*sya;fpb<=$unsigned(fyb)*syb;neg_a<=fya<0;neg_b<=fyb<0;
 row_a<=neg_a?10'd0:((|fpa[36:22]) || fpa[21:12]>10'd959)?10'd959:fpa[21:12];
 row_b<=neg_b?10'd0:((|fpb[36:22]) || fpb[21:12]>10'd959)?10'd959:fpb[21:12];
end
// All dependencies are explicit: the row can stay unchanged across a new
// frame while effect, progress or conveyor geometry changes.
function select_b;input [9:0] row;input enabled;input [5:0] step;
 input [1:0] kind;input signed [12:0] top_pos;reg [9:0] rank;begin
 rank={row[0],row[3],row[6],row[1],row[4],row[7],row[2],row[5],row[8],row[9]} ^ 10'h12b;
 select_b=enabled && (step==32 || (kind==0 && {1'b0,row[5:0]}<{step,1'b0}) ||
  (kind==1 && (top_pos[12] || {3'd0,row}>=$unsigned(top_pos))) ||
  (kind==2 && {1'b0,rank}<{step,5'd0}) || (kind==3 && step>=16));
end endfunction
wire fetch_b=select_b(fetch_y,trans,phase,fx,new_top);reg choose_b;
wire signed [12:0] flip_dy=$signed({3'd0,y})-13'sd480;
reg signed [12:0] tilt;
always @(posedge pixel_clk)if(!de)begin
 choose_b<=select_b(y,trans,phase,fx,new_top);
 tilt<=(trans && fx==3 && phase!=0 && phase!=16 && phase!=32)?
  (phase<16?(flip_dy>>>3):-(flip_dy>>>3)):13'sd0;
end
wire signed [12:0] dxa=$signed({2'd0,x})-(la+tilt),dxb=$signed({2'd0,x})-(lb+tilt);
// Row initialization settles in horizontal blanking. Visible pixels use a
// fixed-point accumulator, avoiding a combinational multiply per pixel.
reg signed [12:0] initial_xa,initial_xb;
reg signed [37:0] initial_pa,initial_pb,xa_product,xb_product;
always @(posedge pixel_clk)begin
 initial_xa<=-(la+tilt);initial_xb<=-(lb+tilt);
 initial_pa<=initial_xa*$signed({1'b0,sxa});initial_pb<=initial_xb*$signed({1'b0,sxb});
 if(!de)begin xa_product<=initial_pa;xb_product<=initial_pb;end
 else begin xa_product<=xa_product+$signed({1'b0,sxa});xb_product<=xb_product+$signed({1'b0,sxb});end
end
// Clamp the integer part without a 25-bit subtractor on the line-RAM path.
// For the low eleven bits, >=1280 is bit10 && (bit9 || bit8).
wire xa_high=(|xa_product[36:23]) || (xa_product[22] && (|xa_product[21:20]));
wire xb_high=(|xb_product[36:23]) || (xb_product[22] && (|xb_product[21:20]));
wire [10:0] source_xa=xa_product[37]?11'd0:xa_high?11'd1279:xa_product[22:12];
wire [10:0] source_xb=xb_product[37]?11'd0:xb_high?11'd1279:xb_product[22:12];
wire [23:0] pa,pb;
scanline_fetch fetch(.mem_clk(mem_clk),.pixel_clk(pixel_clk),.rst_mem(rst_mem),.rst_pixel(rst_pixel),
 .init_done(init_done),.refresh(refresh),.busy(busy),.writer_busy(writer_busy),.read_valid(read_valid),.read_data(read_data),
 .read_enable(read_enable),.read_address(read_address),.reader_busy(reader_busy),
 .request(request),.slot(fetch_y[0]),.source_y(fetch_b?row_b:row_a),.bank_a(fetch_b?bb:ba),
 .ready(ready),.completed_slot(completed_slot),.display_slot(y[0]),.read_pixel(de),
 .x_a(choose_b?source_xb:source_xa),.pixel_a(pa));
assign pb=pa;
wire row_ready=y[0]?(line_valid[1] && tag1==y):(line_valid[0] && tag0==y);
reg line_good;
reg underrun_event;
// Keep the line deadline decision off the saturating counter's enable path.
// The event belongs to the first visible pixel and is counted one clock later.
always @(posedge pixel_clk or posedge rst_pixel)begin
 if(rst_pixel)begin underrun_event<=0;underruns<=0;end
 else begin
  underrun_event<=de && !de_d && active && !row_ready;
  if(underrun_event && underruns!=16'hffff)underruns<=underruns+1'b1;
 end
end
wire display_ready=(de && !de_d)?row_ready:line_good;
always @(posedge pixel_clk or posedge rst_pixel)begin
 if(rst_pixel)begin
  vs_d<=1;de_d<=0;x<=0;y<=0;start_pipe<=0;ba<=0;bb<=0;fx<=0;active<=0;trans<=0;phase<=0;flip_factor<=512;
  frame_movie<=0;frame_fit<=0;frame_zoom<=2;frame_wa<=640;frame_ha<=480;frame_wb<=640;frame_hb<=480;epoch<=0;requested_epoch<=0;
  fetch_y<=0;requested_y<=0;tag0<=0;tag1<=0;pending<=0;request<=0;outstanding<=0;seen_busy<=0;first_line<=0;boot_second<=0;
  line_valid<=0;line_blank<=0;line_good<=0;fetch_settle<=0;
 end else begin
  vs_d<=vs;de_d<=de;start_pipe<={start_pipe[2:0],frame_start};request<=0;
  if(!vs)begin x<=0;y<=0;end
  else if(de)begin if(x<1279)x<=x+1'b1;end
  else begin x<=0;if(de_d)y<=y+1'b1;end
  if(start_pipe[1])begin
   ba<=bank_a;bb<=bank_b;fx<=effect;active<=valid;trans<=transition;phase<=progress;
   frame_movie<=movie;frame_fit<=fit;frame_zoom<=zoom;
   frame_wa<=native_wa;frame_ha<=native_ha;frame_wb<=native_wb;frame_hb<=native_hb;
   flip_factor<=transition && effect==3?flip_cos(progress):10'd512;
  end
  if(frame_start)begin epoch<=epoch+1'b1;first_line<=1;boot_second<=1;pending<=0;line_valid<=0;end
  if(first_line && ga && gb && start_pipe==0 && !frame_start)begin
   first_line<=0;fetch_y<=0;pending<=active;
  end
  if(de && !de_d)begin
   line_good<=row_ready;
  end
  // Retire current slot after its last visible pixel. Prefetch y+2 immediately,
  // using the following horizontal blank as additional deadline margin.
  if(!de && de_d && y<958)begin fetch_y<=y+2'd2;pending<=active;end
  if(!pending)fetch_settle<=0;else if(fetch_settle<7)fetch_settle<=fetch_settle+1'b1;
  if(pending && fetch_settle==7 && ready && ga && gb && !outstanding && !request && !frame_start)begin
   pending<=0;
   if(frame_movie && ((fetch_b?row_b:row_a)<120 || (fetch_b?row_b:row_a)>=840))begin
    // Borders are generated here; no TF effect asset and no SDRAM traffic.
    line_blank[fetch_y[0]]<=1;line_valid[fetch_y[0]]<=1;
    if(fetch_y[0])tag1<=fetch_y;else tag0<=fetch_y;
    if(boot_second && fetch_y==0)begin fetch_y<=1;pending<=active;boot_second<=0;end
   end else begin
    request<=1;requested_y<=fetch_y;requested_epoch<=epoch;outstanding<=1;seen_busy<=0;
    line_blank[fetch_y[0]]<=0;line_valid[fetch_y[0]]<=0;
   end
  end
  if(outstanding)begin
   if(!ready)seen_busy<=1;
   if(ready && seen_busy)begin
    outstanding<=0;
    if(requested_epoch==epoch && !frame_start)begin
     line_valid[requested_y[0]]<=1;
     if(requested_y[0])tag1<=requested_y;else tag0<=requested_y;
     if(boot_second && requested_y==0)begin fetch_y<=1;pending<=active;boot_second<=0;end
    end
   end
  end
 end
end
reg signed [12:0] left_a,right_a,left_b,right_b,bottom_a,bottom_b;
always @(posedge pixel_clk)if(!de)begin
 left_a<=la+tilt;right_a<=la+tilt+$signed({1'b0,wa});
 left_b<=lb+tilt;right_b<=lb+tilt+$signed({1'b0,wb});
 bottom_a<=old_top+$signed({1'b0,ha});bottom_b<=new_top+$signed({1'b0,hb});
end
wire in_a=$signed({2'd0,x})>=left_a && $signed({2'd0,x})<right_a && $signed({3'd0,y})>=old_top && $signed({3'd0,y})<bottom_a;
wire in_b=$signed({2'd0,x})>=left_b && $signed({2'd0,x})<right_b && $signed({3'd0,y})>=new_top && $signed({3'd0,y})<bottom_b;
reg hs_q,vs_q,de_q,show_q,choose_q;
always @(posedge pixel_clk)begin
 hs_q<=hs;vs_q<=vs;de_q<=de && !rst_pixel;
 show_q<=active && display_ready && !line_blank[y[0]] && (choose_b?in_b:in_a);
 choose_q<=choose_b;
 out_hs<=hs_q;out_vs<=vs_q;out_de<=de_q;
 content_valid<=de_q && show_q && !rst_pixel;
 out_rgb<=show_q?(choose_q?pb:pa):24'hf5f7f1;
end
endmodule
