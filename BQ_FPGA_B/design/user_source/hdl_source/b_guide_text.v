// Fixed words, selected and placed by runtime FPGA scene state.
module b_guide_text(input clk,input [5:0] label,index,output [7:0] character);
reg [7:0] text_rom[0:1023],q;reg outside;
initial begin
`include "b_guide_text_init.vh"
end
always @(posedge clk)begin q<=text_rom[{label,index[3:0]}];outside<=|index[5:4];end
assign character=outside ? 8'd0:q;
endmodule
