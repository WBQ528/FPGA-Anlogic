// verified RGB565 scanout. Two completed line slots, immutable displayed
// bank, and a frame epoch. No depth estimates or viewpoint resampling remain.
// Garden and itinerary panes preserve image aspect; map stays at native canvas.
module b_scene_display(
 input mem_clk,pixel_clk,rst_mem,rst_pixel,
 input init_done,refresh,busy,writer_busy,read_valid,input [31:0] read_data,
 output read_enable,output [20:0] read_address,output reader_busy,
 input hs,vs,de,input valid,input [1:0] page,bank,input [10:0] native_width,native_height,
 output reg out_hs,out_vs,out_de,output [23:0] out_rgb,
 output reg [10:0] out_x,output reg [9:0] out_y,output reg [15:0] underruns,output reg cover_busy
);
reg vs_d,de_d;reg [10:0] x;reg [9:0] y;
wire frame_start=vs_d && !vs;
reg [3:0] start_pipe;reg [1:0] active_bank,active_page,old_bank;reg active;
reg [10:0] cover_pixels;
reg [10:0] old_left,old_width;reg [9:0] old_top,old_height;
reg [23:0] old_step_x,old_step_y;
reg [9:0] fetch_y,requested_y,tag0,tag1;
reg [7:0] epoch,requested_epoch;reg [1:0] pending_age;
reg pending,request,outstanding,seen_busy,first_line,boot_second;
reg [1:0] line_valid;wire ready,completed_slot;
wire [23:0] rgb;
reg line_good,good_q,active_q;reg [23:0] last_good_rgb;
wire row_ready=y[0] ? (line_valid[1] && tag1==y):(line_valid[0] && tag0==y);
wire geo_ready;wire [10:0] pane_left,pane_width;wire [9:0] pane_top,pane_height;wire [23:0] step_x,step_y;
b_view_geometry geometry(.clk(pixel_clk),.rst(rst_pixel),.start(start_pipe[1]),.page(page),.native_width(native_width),.native_height(native_height),
 .ready(geo_ready),.left(pane_left),.top(pane_top),.width(pane_width),.height(pane_height),.step_x(step_x),.step_y(step_y));
reg [23:0] phase_x;reg [33:0] row_product;reg [9:0] source_y;
wire [10:0] source_x=phase_x[23:12]>1279 ? 11'd1279:phase_x[22:12];
// Right-to-left cover. Both complete textures remain owned during 24 frames.
// Fetch the old and new source rows into separate halves of the line store.
// Extra reads occur only during a cover; ordinary scanout remains one row.
reg [10:0] cover_shift,cover_edge,new_left,new_right,old_right;
always @(posedge pixel_clk)begin
 cover_shift<=cover_busy ? 11'd896-cover_pixels:11'd0;
 cover_edge<=11'd32+cover_shift;
 new_left<=pane_left+cover_shift;
 new_right<=pane_left+cover_shift+pane_width;
 old_right<=old_left+old_width;
end
wire show_new=!cover_busy || x>=cover_edge;
wire [10:0] visible_left=show_new?new_left:old_left;
wire [10:0] visible_right=show_new?new_right:old_right;
wire [9:0] visible_top=show_new?pane_top:old_top,visible_height=show_new?pane_height:old_height;
wire inside_x=x>=visible_left && x<visible_right;
wire in_pane=y>=visible_top && y<visible_top+visible_height && inside_x &&
 (!cover_busy || (x>=32 && x<928));
reg [23:0] old_phase_x;
reg [33:0] old_row_product;reg [9:0] old_source_y;
reg [10:0] row_offset,old_row_offset;
always @(posedge pixel_clk)begin
 row_offset<=fetch_y>=pane_top ? fetch_y-pane_top:11'd0;
 old_row_offset<=fetch_y>=old_top ? fetch_y-old_top:11'd0;
 row_product<=row_offset*step_y;old_row_product<=old_row_offset*old_step_y;
 source_y<=row_product[33:12]>719 ? 10'd719:row_product[21:12];
 old_source_y<=old_row_product[33:12]>719 ? 10'd719:old_row_product[21:12];
end
always @(posedge pixel_clk or posedge rst_pixel)
 if(rst_pixel)begin phase_x<=0;old_phase_x<=0;end
 else if(!de)begin phase_x<=0;old_phase_x<=0;end
 else begin
  if(x>=new_left)phase_x<=phase_x+step_x;
  if(x>=old_left)old_phase_x<=old_phase_x+old_step_x;
 end
wire [10:0] old_source_x=old_phase_x[23:12]>1279?11'd1279:old_phase_x[22:12];
// Only fetch the source prefixes actually visible on either side of the
// moving cover edge. Two whole rows would exceed the 50 MHz SDRAM budget.
reg [10:0] new_visible,old_visible;
reg [34:0] new_range,old_range;
reg [9:0] new_words,old_words;
always @(posedge pixel_clk)begin
 new_visible<=11'd928>new_left?11'd928-new_left:11'd0;
 old_visible<=cover_edge>old_left?cover_edge-old_left:11'd0;
 new_range<=new_visible*step_x;old_range<=old_visible*old_step_x;
 new_words<=new_range[34:13]>=638?10'd640:new_range[22:13]+10'd2;
 old_words<=old_range[34:13]>=638?10'd640:old_range[22:13]+10'd2;
end
wire current_good=de && !de_d ? row_ready:line_good;
b_scanline_fetch fetch(.mem_clk(mem_clk),.pixel_clk(pixel_clk),.rst_mem(rst_mem),.rst_pixel(rst_pixel),
 .init_done(init_done),.refresh(refresh),.busy(busy),.writer_busy(writer_busy),.read_valid(read_valid),.read_data(read_data),
 .read_enable(read_enable),.read_address(read_address),.reader_busy(reader_busy),
 .request(request),.slot(fetch_y[0]),.source_y(source_y),.bank_a(active_bank),
 .dual(cover_busy),.words_a(new_words),.words_b(old_words),.source_y_b(old_source_y),.bank_b(old_bank),.color_b(!show_new),
 .ready(ready),.completed_slot(completed_slot),.display_slot(y[0]),.color_slot(y[0]),.read_pixel(de),
 .depth_x(x),.x_a(show_new?source_x:old_source_x),.relative_depth(),.pixel_a(rgb));
assign out_rgb=!active_q ? 24'hf3f5e9:good_q ? rgb:last_good_rgb;
always @(posedge pixel_clk or posedge rst_pixel)begin
 if(rst_pixel)begin
  vs_d<=1;de_d<=0;x<=0;y<=0;start_pipe<=0;active_bank<=0;active<=0;active_page<=0;old_bank<=0;cover_busy<=0;cover_pixels<=0;
  old_left<=0;old_width<=0;old_top<=0;old_height<=0;old_step_x<=4096;old_step_y<=4096;
  fetch_y<=0;requested_y<=0;tag0<=0;tag1<=0;epoch<=0;requested_epoch<=0;pending_age<=0;
  pending<=0;request<=0;outstanding<=0;seen_busy<=0;first_line<=0;boot_second<=0;line_valid<=0;line_good<=0;
  good_q<=0;active_q<=0;last_good_rgb<=24'hf3f5e9;underruns<=0;
  out_hs<=1;out_vs<=1;out_de<=0;out_x<=0;out_y<=0;
 end else begin
  vs_d<=vs;de_d<=de;start_pipe<={start_pipe[2:0],frame_start};request<=0;
  out_hs<=hs;out_vs<=vs;out_de<=de;out_x<=x;out_y<=y;good_q<=current_good;active_q<=active && in_pane && geo_ready;
  if(out_de && good_q)last_good_rgb<=rgb;
  if(!vs)begin x<=0;y<=0;end
  else if(de)begin if(x<1279)x<=x+1'b1;end
  else begin x<=0;if(de_d)y<=y+1'b1;end
  if(start_pipe[1])begin
   active_bank<=bank;active<=valid;active_page<=page;
   if(page!=1 || !valid)begin cover_busy<=0;cover_pixels<=0;end
   else if(active && active_page==1 && bank!=active_bank)begin
    old_bank<=active_bank;old_left<=pane_left;old_top<=pane_top;old_width<=pane_width;old_height<=pane_height;
    old_step_x<=step_x;old_step_y<=step_y;cover_busy<=1;cover_pixels<=0;
   end else if(cover_busy)begin
    if(cover_pixels>=858)begin cover_pixels<=896;cover_busy<=0;end
    else cover_pixels<=cover_pixels+11'd38;
   end
  end
  if(frame_start)begin epoch<=epoch+1'b1;first_line<=1;boot_second<=1;pending<=0;line_valid<=0;end
  if(first_line && start_pipe==0 && !frame_start)begin first_line<=0;fetch_y<=0;pending<=active;pending_age<=0;end
  if(de && !de_d)begin
   line_good<=row_ready;
   if(active && !row_ready && underruns!=16'hffff)underruns<=underruns+1'b1;
  end
  if(!de && de_d && y<718)begin fetch_y<=y+2'd2;pending<=active;pending_age<=0;end
  if(pending && pending_age!=3)pending_age<=pending_age+1'b1;
  if(pending && pending_age==3 && ready && geo_ready && !outstanding && !request && !frame_start)begin
   request<=1;requested_y<=fetch_y;requested_epoch<=epoch;pending<=0;outstanding<=1;seen_busy<=0;line_valid[fetch_y[0]]<=0;
  end
  if(outstanding)begin
   if(!ready)seen_busy<=1;
   if(ready && seen_busy)begin
    outstanding<=0;
    // Discard a late row from the preceding frame/bank, even at the same y.
    if(requested_epoch==epoch && !frame_start)begin
     line_valid[requested_y[0]]<=1;
     if(requested_y[0])tag1<=requested_y;else tag0<=requested_y;
     if(boot_second && requested_y==0)begin fetch_y<=1;pending<=active;pending_age<=0;boot_second<=0;end
    end
   end
  end
 end
end
endmodule
