// Derived ONLY inside FPGA from the just-decoded ordinary BMP pixels.
// Garden-page location map: whole 1280x720 ->128x72, RGB332, generated here.
// Four permanent garden caches: 160x72 RGB332 in the SAME twelve BRAM32K.
// Full-size introduction photos cannot evict them. Valid only after complete decode.
// No texture effect, mask, depth or route file exists on TF.
module b_runtime_thumbnails(
 input load_clk,pixel_clk,rst,input frame_reset,pixel_valid,
 input [1:0] load_bank,input [23:0] rgb,
 input [3:0] load_asset,input load_complete,output reg [3:0] pinned_valid,
 input [13:0] map_address,output [7:0] map_pixel,
 input [15:0] photo_address,output [7:0] photo_pixel
);
reg [7:0] map_main[0:8191],map_tail[0:1023];reg [7:0] first;reg [7:0] map_main_q,map_tail_q;reg tail_q;
reg [10:0] x;reg [9:0] file_y;wire [9:0] y=10'd719-file_y;
wire [7:0] color332={rgb[23:21],rgb[15:13],rgb[7:6]};
// Exact quotient/remainder counters for sequential raster sampling.
// Avoid per-pixel /10 and %10 on the SD-domain RAM write-enable path.
reg [6:0] mx,my;reg [3:0] mod_x,mod_y;
always @(posedge load_clk or posedge rst)begin
 if(rst)begin mx<=0;my<=71;mod_x<=0;mod_y<=9;end
 else if(frame_reset)begin mx<=0;my<=71;mod_x<=0;mod_y<=9;end
 else if(pixel_valid)begin
  if(x==1279)begin
   mx<=0;mod_x<=0;
   if(mod_y==0)begin mod_y<=9;my<=my-1'b1;end else mod_y<=mod_y-1'b1;
  end else if(mod_x==9)begin mx<=mx+1'b1;mod_x<=0;end else mod_x<=mod_x+1'b1;
 end
end
wire [13:0] ma={my,mx};
wire primary_asset=load_asset>=1 && load_asset<=4;
wire [1:0] garden_index=load_asset[1:0]-2'd1;
wire capture=primary_asset && !pinned_valid[garden_index];
wire [12:0] thumb_offset=({6'd0,my}<<6)+({6'd0,my}<<4)+{6'd0,x[10:4]};
wire [14:0] pa=({13'd0,garden_index}<<12)+({13'd0,garden_index}<<11)+thumb_offset;
wire photo_write=pixel_valid && capture && x[2:0]==0 && x[3] && mod_y==0;
always @(posedge load_clk or posedge rst)
 if(rst)pinned_valid<=0;
 else if(load_complete && primary_asset)pinned_valid[garden_index]<=1;
reg photo_write_q;reg [14:0] pa_q;reg [15:0] color_q;
always @(posedge load_clk)begin photo_write_q<=photo_write && !rst && !frame_reset;pa_q<=pa;color_q<={color332,first};end
b_photo_ram photos(.write_clk(load_clk),.read_clk(pixel_clk),.write_enable(photo_write_q),.write_address(pa_q),.write_data(color_q),
 .read_address(photo_address),.read_data(photo_pixel));
always @(posedge pixel_clk)begin
 tail_q<=map_address[13];map_main_q<=map_main[map_address[12:0]];map_tail_q<=map_tail[map_address[9:0]];
end
assign map_pixel=tail_q ? map_tail_q:map_main_q;
reg map_we;reg [13:0] map_wa;reg [7:0] map_wd;
always @(posedge load_clk)begin
 map_we<=pixel_valid && !rst && !frame_reset && load_bank==0 && mod_x==0 && mod_y==0;
 map_wa<=ma;map_wd<=color332;
 if(map_we)begin
  if(map_wa[13])map_tail[map_wa[9:0]]<=map_wd;else map_main[map_wa[12:0]]<=map_wd;
 end
 if(pixel_valid && capture && x[3:0]==0 && mod_y==0)first<=color332;
end
always @(posedge load_clk or posedge rst)begin
 if(rst)begin x<=0;file_y<=0;end
 else if(frame_reset)begin x<=0;file_y<=0;end
 else if(pixel_valid)begin if(x==1279)begin x<=0;file_y<=file_y+1'b1;end else x<=x+1'b1;end
end
endmodule
