// Fixed glyph atlas: four native 32K bit ROMs. Text is one byte-indexed ROM.
// The rendered words and cue selection are entirely runtime FPGA operations.
module a_subtitle_font(input clk,input [16:0] address,output pixel);
wire [15:0] d0,d1,d2,d3;reg [1:0] bank;reg [3:0] bit_position;
always @(posedge clk)begin bank<=address[16:15];bit_position<=address[3:0];end
a_subtitle_bank0 b0(.clk(clk),.address(address[14:4]),.data(d0));
a_subtitle_bank1 b1(.clk(clk),.address(address[14:4]),.data(d1));
a_subtitle_bank2 b2(.clk(clk),.address(address[14:4]),.data(d2));
a_subtitle_bank3 b3(.clk(clk),.address(address[14:4]),.data(d3));
// Register each RAM's one-bit selection locally before the four-bank mux.
reg [3:0] bits_q;reg [1:0] bank_q;
always @(posedge clk)begin bits_q<={d3[bit_position],d2[bit_position],d1[bit_position],d0[bit_position]};bank_q<=bank;end
assign pixel=bits_q[bank_q];
endmodule
module a_subtitle_text(input clk,input [9:0] address,output [7:0] character);
wire [15:0] data;reg half;
always @(posedge clk)half<=address[0];
a_subtitle_bank4 text_rom(.clk(clk),.address({2'd0,address[9:1]}),.data(data));
assign character=half ? data[15:8]:data[7:0];
endmodule
`include "a_subtitle_storage.vh"
