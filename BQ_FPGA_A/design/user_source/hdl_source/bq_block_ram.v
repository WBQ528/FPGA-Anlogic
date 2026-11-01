// 2048 x 32 compressed-row store in two dedicated 32-Kbit blocks.
// Read latency is exactly one cycle, matching the inferred-RAM implementation.
module bq_block_ram(input clk,input we,input [10:0] wa,ra,
 input [31:0] data,output [31:0] q);
`ifdef UI_FONT_SIM
 reg [31:0] ram[0:2047];reg [31:0] sim_q;
 always @(posedge clk)begin
  if(we)ram[wa]<=data;
  sim_q<=ram[ra];
 end
 assign q=sim_q;
`else
 genvar k;
 generate for(k=0;k<2;k=k+1)begin: slices
  EG_PHY_BRAM32K #(.MODE("DP16K"),.DATA_WIDTH_A("16"),.DATA_WIDTH_B("16"),
   .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL")) memory(
   .doa(),.dob(q[k*16+:16]),.dia(data[k*16+:16]),.dib(16'd0),.addra(wa),.addrb(ra),
   .bytea(1'b0),.bytewea(1'b0),.byteb(1'b0),.byteweb(1'b0),.csa(1'b1),.wea(we),.csb(1'b1),.web(1'b0),
   .clka(clk),.clkb(clk),.rsta(1'b0),.rstb(1'b0),.ocea(1'b1),.oceb(1'b1));
 end endgenerate
`endif
endmodule
