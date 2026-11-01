// E3 sector-buffered nearest-neighbor scaler, positive/bottom-up BGR24 BMP.
// Source 1..1280 x 1..1024 -> exactly 1280x960 pixels in file-row order.
// 512-byte sector + one source row; never a second full-frame buffer.
// Sector sender must await sector_done before sending the next sector.
// Output pulse only when output_ready; drain completion includes last pixel.
module bmp_scale_stream(
 input clk,rst,start,input [10:0] width,height,
 input [31:0] pixel_offset,pixel_end,input [12:0] row_stride,
 input byte_valid,input [7:0] byte_data,input sector_end,output reg sector_done,
 input output_ready,output pixel_valid,output [23:0] pixel
);
reg [7:0] sector[0:511];reg [23:0] line[0:1279];
reg [8:0] wr_addr;reg [9:0] rd_addr;reg [7:0] byte_q;
reg [23:0] line_q;reg [15:0] partial;
reg [31:0] position;reg [12:0] row_byte;
reg [10:0] source_x,source_y,target_y,read_x;
reg [10:0] dest_x;reg [9:0] dest_y;
// Remainder plus source size is <1920 horizontally and <1504 vertically.
reg [11:0] acc_x,acc_y;
reg [1:0] channel;reg [3:0] state;
reg [12:0] row_last;
reg selected_row,inside_pixels,color_byte,last_row_byte;
localparam IDLE=0,BYTE_READ=1,BYTE_USE=2,ROW_CHECK=3,PIX_READ=4,PIX_SEND=5,X_STEP=6,Y_STEP=7,NEXT_BYTE=8;
assign pixel_valid=(state==PIX_SEND) && output_ready && !rst;
assign pixel=line_q;
wire [12:0] color_bytes={2'd0,width}+({2'd0,width}<<1);
always @(posedge clk)begin
 selected_row<=source_y==target_y && dest_y<960;
 inside_pixels<=position>=pixel_offset && position<pixel_end;
 color_byte<=row_byte<color_bytes;
 if(start)row_last<=row_stride-13'd1;
 last_row_byte<=row_byte==row_last;
 if(byte_valid)sector[wr_addr]<=byte_data;
 if(state==BYTE_READ)byte_q<=sector[rd_addr[8:0]];
 if(state==PIX_READ)line_q<=line[read_x];
 if(state==BYTE_USE && inside_pixels && color_byte && channel==2)
  line[source_x]<={byte_q,partial};
end
always @(posedge clk or posedge rst)begin
 if(rst)begin
  wr_addr<=0;rd_addr<=0;position<=0;row_byte<=0;source_x<=0;source_y<=0;target_y<=0;
  read_x<=0;dest_x<=0;dest_y<=0;acc_x<=0;acc_y<=0;channel<=0;partial<=0;
  state<=IDLE;sector_done<=0;
 end else begin
  sector_done<=0;
  if(byte_valid)wr_addr<=wr_addr+1'b1;
  if(start)begin
   wr_addr<=0;rd_addr<=0;position<=0;row_byte<=0;source_x<=0;source_y<=0;target_y<=0;
   read_x<=0;dest_x<=0;dest_y<=0;acc_x<=0;acc_y<=0;channel<=0;state<=IDLE;
  end else case(state)
   IDLE:if(sector_end)begin wr_addr<=0;rd_addr<=0;state<=BYTE_READ;end
   BYTE_READ:state<=BYTE_USE;
   BYTE_USE:begin
    position<=position+1'b1;rd_addr<=rd_addr+1'b1;state<=NEXT_BYTE;
    if(inside_pixels)begin
     if(color_byte)case(channel)
      0:begin partial[7:0]<=byte_q;channel<=1;end
      1:begin partial[15:8]<=byte_q;channel<=2;end
      2:begin source_x<=source_x+1'b1;channel<=0;end
      default:channel<=0;
     endcase
     if(last_row_byte)begin
      row_byte<=0;source_x<=0;channel<=0;state<=ROW_CHECK;
     end else row_byte<=row_byte+1'b1;
    end
   end
   ROW_CHECK:begin
    if(selected_row)begin dest_x<=0;read_x<=0;acc_x<=0;state<=PIX_READ;end
    else begin source_y<=source_y+1'b1;state<=NEXT_BYTE;end
   end
   PIX_READ:state<=PIX_SEND;
   PIX_SEND:if(output_ready)begin
    if(dest_x==1279)begin dest_y<=dest_y+1'b1;acc_y<=acc_y+height;state<=Y_STEP;end
    else begin dest_x<=dest_x+1'b1;acc_x<=acc_x+width;state<=X_STEP;end
   end
   X_STEP:if(acc_x>=1280)begin acc_x<=acc_x-1280;read_x<=read_x+1'b1;end else state<=PIX_READ;
   Y_STEP:if(acc_y>=960)begin acc_y<=acc_y-960;target_y<=target_y+1'b1;end else state<=ROW_CHECK;
   NEXT_BYTE:if(rd_addr==512)begin sector_done<=1;state<=IDLE;end else state<=BYTE_READ;
   default:state<=IDLE;
  endcase
 end
end
endmodule
