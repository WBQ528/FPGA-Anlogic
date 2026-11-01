// Twelve BRAM32K blocks hold four 160x72 RGB332 pinned garden caches. Packing two
// RGB332 samples per 16-bit word uses the otherwise idle BRAM32K resources.
module b_photo_ram(input write_clk,read_clk,input write_enable,input [14:0] write_address,input [15:0] write_data,
 input [15:0] read_address,output [7:0] read_data);
`ifdef B_SIM
reg [15:0] memory[0:24575];reg [15:0] q;reg sim_half;
always @(posedge write_clk)if(write_enable)memory[write_address]<=write_data;
always @(posedge read_clk)begin q<=memory[read_address[15:1]];sim_half<=read_address[0];end
assign read_data=sim_half?q[15:8]:q[7:0];
`else
wire [191:0] words;reg [3:0] bank;reg half;
always @(posedge read_clk)begin bank<=read_address[15:12];half<=read_address[0];end
wire [15:0] selected=words[bank*16+:16];
assign read_data=half?selected[15:8]:selected[7:0];
genvar i;
generate for(i=0;i<12;i=i+1)begin:blocks

 EG_PHY_BRAM32K #(.MODE("DP16K"),.DATA_WIDTH_A("16"),.DATA_WIDTH_B("16"),
 .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL")) storage(
 .doa(),.dob(words[i*16+:16]),.dia(write_data),.dib(16'd0),.addra(write_address[10:0]),.addrb(read_address[11:1]),
 .bytea(1'b0),.bytewea(1'b0),.byteb(1'b0),.byteweb(1'b0),.csa(1'b1),.wea(write_enable && write_address[14:11]==i),.csb(1'b1),.web(1'b0),
 .clka(write_clk),.clkb(read_clk),.rsta(1'b0),.rstb(1'b0),.ocea(1'b1),.oceb(1'b1));

end endgenerate
`endif
endmodule
