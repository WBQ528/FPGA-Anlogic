module b_text_rom(input clk,input [10:0] address,output reg [31:0] row);
reg [31:0] glyphs[0:2047];
initial begin
`include "b_font_init.vh"
end
always @(posedge clk)row<=glyphs[address];
endmodule
