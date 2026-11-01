// Fixed-capacity ROMs reserve BRAM9K headroom without changing glyphs or latency.
module ui_font_rom(input clk,enable,input [12:0] address,output [15:0] data);
reg [12:0] held_address;
reg bank_q,half_q;
always @(posedge clk)if(enable)begin
 held_address<=address;bank_q<=address[12];half_q<=address[0];
end
wire [12:0] read_address=enable?address:held_address;
wire [15:0] low_word,high_word;
ui_font_bank0 low_storage(.clk(clk),.address(read_address[11:1]),.data(low_word));
// The former 1024-byte upper atlas ignored bits 11:10; preserve those aliases.
ui_font_bank1 high_storage(.clk(clk),.address({2'b0,read_address[9:1]}),.data(high_word));
wire [15:0] word_q=bank_q?high_word:low_word;
wire [7:0] bits=half_q?word_q[15:8]:word_q[7:0];
genvar n;
generate for(n=0;n<8;n=n+1)begin:expand_coverage
 assign data[n*2+:2]={2{bits[n]}};
end endgenerate
endmodule
`include "ui_font_storage.vh"
