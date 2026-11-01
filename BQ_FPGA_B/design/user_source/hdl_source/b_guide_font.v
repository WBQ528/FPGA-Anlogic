module b_guide_font(input clk,input [17:0] address,output pixel);
reg [2:0] bank,bank_q;reg [3:0] bit_position;reg [7:0] bank_pixels;
always @(posedge clk)begin bank<=address[17:15];bit_position<=address[3:0];bank_q<=bank;end
wire [15:0] d0;b_guide_bank0 b0(.clk(clk),.address(address[14:4]),.data(d0));
wire [15:0] d1;b_guide_bank1 b1(.clk(clk),.address(address[14:4]),.data(d1));
wire [15:0] d2;b_guide_bank2 b2(.clk(clk),.address(address[14:4]),.data(d2));
wire [15:0] d3;b_guide_bank3 b3(.clk(clk),.address(address[14:4]),.data(d3));
wire [15:0] d4;b_guide_bank4 b4(.clk(clk),.address(address[14:4]),.data(d4));
always @(posedge clk)bank_pixels<={3'd0,d4[bit_position],d3[bit_position],d2[bit_position],d1[bit_position],d0[bit_position]};
assign pixel=bank_pixels[bank_q];
endmodule
`include "b_guide_storage.vh"
