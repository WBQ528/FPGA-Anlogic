// R5 packed RGB565, 1280 pixels/line, 640 words. Two ownership slots.
// A request reserves read priority; every burst stops at a 256-word page.
module b_scanline_fetch(
 input mem_clk,pixel_clk,rst_mem,rst_pixel,
 input init_done,refresh,busy,writer_busy,read_valid,input [31:0] read_data,
 output read_enable,output [20:0] read_address,output reader_busy,
 input request,slot,input [9:0] source_y,input [1:0] bank_a,
 input dual,input [9:0] source_y_b,input [1:0] bank_b,input color_b,
 input [9:0] words_a,words_b,
 output ready,output reg completed_slot,
 input display_slot,color_slot,read_pixel,input [10:0] x_a,input [10:0] depth_x,output [7:0] relative_depth,output [23:0] pixel_a
);
reg [31:0] main_line[0:2047],tail_line[0:511];
reg [31:0] main_q,tail_q;reg tail_select,half_select;
// ordinary image scanout only. No depth RAM or inferred geometry.
wire [9:0] line_words=second?held_words_b:held_words_a;
wire [9:0] remaining=line_words-line_position;
wire [8:0] page_remaining=9'd256-{1'b0,address[7:0]};
wire receive_word=read_valid && (state==ISSUE || state==DRAIN);
assign relative_depth=8'd0;
wire [15:0] color=half_select?(tail_select?tail_q[31:16]:main_q[31:16]):(tail_select?tail_q[15:0]:main_q[15:0]);
assign pixel_a={color[15:11],color[15:13],color[10:5],color[10:9],color[4:0],color[4:2]};
reg req_toggle,ack_toggle;reg [1:0] ack_sync,req_sync;
reg held_slot;reg [9:0] held_y;reg [1:0] held_a,held_b;reg [9:0] held_y_b;reg held_dual,second;reg [9:0] held_words_a,held_words_b;
reg seen;reg [2:0] state;reg current_slot;
reg [20:0] address,row_offset;reg [9:0] line_position;
reg [8:0] issued,returned,burst_length;reg [11:0] store_address;
localparam IDLE=0,PREPARE=1,CHECK=2,ISSUE=3,DRAIN=4,FINISH=5;
function [20:0] bank_base;input [1:0] bank;begin case(bank)
 0:bank_base=0;1:bank_base=460800;2:bank_base=921600;default:bank_base=1382400;
endcase end endfunction
// Four slots use 7.03125MiB of the 8MiB SDRAM.
assign ready=(ack_sync[1]==req_toggle);assign read_enable=(state==ISSUE);
assign read_address=address;assign reader_busy=(state!=IDLE && state!=FINISH);
wire [11:0] rd=(color_b?12'd1280:12'd0)+(color_slot?12'd640:12'd0)+{2'd0,x_a[10:1]};
always @(posedge pixel_clk)if(read_pixel)begin
 tail_select<=rd[11];half_select<=x_a[0];
 if(rd[11])tail_q<=tail_line[rd[8:0]];else main_q<=main_line[rd[10:0]];
end
always @(posedge mem_clk)if(receive_word)begin
 if(store_address[11])tail_line[store_address[8:0]]<=read_data;
 else main_line[store_address[10:0]]<=read_data;
end
always @(posedge pixel_clk or posedge rst_pixel)begin
 if(rst_pixel)begin req_toggle<=0;ack_sync<=0;held_slot<=0;held_y<=0;held_a<=0;held_b<=0;held_y_b<=0;held_dual<=0;held_words_a<=640;held_words_b<=640;completed_slot<=0;end
 else begin ack_sync<={ack_sync[0],ack_toggle};if(ready)begin completed_slot<=held_slot;
  if(request)begin held_slot<=slot;held_y<=source_y;held_a<=bank_a;held_b<=bank_b;held_y_b<=source_y_b;held_dual<=dual;held_words_a<=dual?words_a:10'd640;held_words_b<=words_b;req_toggle<=~req_toggle;end
 end end
end
always @(posedge mem_clk or posedge rst_mem)begin
 if(rst_mem)begin req_sync<=0;ack_toggle<=0;seen<=0;state<=IDLE;address<=0;row_offset<=0;
  second<=0;current_slot<=0;line_position<=0;issued<=0;returned<=0;store_address<=0;burst_length<=128;end
 else begin
  req_sync<={req_sync[0],req_toggle};
  if(read_valid && (state==ISSUE || state==DRAIN))begin returned<=returned+1'b1;store_address<=store_address+1'b1;end
  case(state)
   IDLE:if(req_sync[1]!=seen && init_done)begin seen<=req_sync[1];current_slot<=held_slot;second<=0;
    row_offset<=({11'd0,held_y}<<9)+({11'd0,held_y}<<7);line_position<=0;state<=PREPARE;end
   PREPARE:begin address<=bank_base(second?held_b:held_a)+row_offset;store_address<=(second?12'd1280:12'd0)+(current_slot?12'd640:12'd0);state<=CHECK;end
   CHECK:begin issued<=0;returned<=0;burst_length<=remaining<page_remaining?remaining[8:0]:page_remaining;
    if(!refresh && !busy && !writer_busy)state<=ISSUE;end
   ISSUE:begin address<=address+1'b1;issued<=issued+1'b1;if(issued+1'b1==burst_length)state<=DRAIN;end
   DRAIN:if(returned==burst_length && !busy)begin
    if(line_position+burst_length==line_words)begin
     if(held_dual && !second)begin second<=1;row_offset<=({11'd0,held_y_b}<<9)+({11'd0,held_y_b}<<7);line_position<=0;state<=PREPARE;end
     else state<=FINISH;
    end
    else begin line_position<=line_position+burst_length;state<=CHECK;end
   end
   FINISH:begin ack_toggle<=seen;state<=IDLE;end
   default:state<=IDLE;
  endcase
 end
end
endmodule
