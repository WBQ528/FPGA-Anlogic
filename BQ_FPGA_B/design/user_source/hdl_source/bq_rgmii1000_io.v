// RGMII 1000FD, low nibble on rising edge, high nibble on falling edge.
// Edge-aligned transmitted clock; RTL8211E internal TX/RX skew is read back.
module bq_rgmii1000_io(input tx_clk,tx_rst_n,rx_rst_n,io_enable,
 input [7:0] tx_byte,input tx_enable,
 input phy_rxc,input [3:0] phy_rxd,input phy_rxctl,
 output phy_txc,output [3:0] phy_txd,output phy_txctl,
 output [7:0] rx_byte,output rx_valid,rx_error);
wire txc_i,txctl_i;wire [3:0] txd_i;wire ctl_rise,ctl_fall;genvar i;
`ifdef BQ_NET_SIM
reg [3:0] r1,r2,f1,f2;reg cr1,cr2,cf1,cf2;
always @(posedge phy_rxc or negedge rx_rst_n)
 if(!rx_rst_n)begin r1<=0;r2<=0;f2<=0;cr1<=0;cr2<=0;cf2<=0;end
 else begin r1<=phy_rxd;r2<=r1;f2<=f1;cr1<=phy_rxctl;cr2<=cr1;cf2<=cf1;end
always @(negedge phy_rxc or negedge rx_rst_n)
 if(!rx_rst_n)begin f1<=0;cf1<=0;end else begin f1<=phy_rxd;cf1<=phy_rxctl;end
assign rx_byte={f2,r2};assign ctl_rise=cr2;assign ctl_fall=cf2;
reg [7:0] tb;reg te;
always @(posedge tx_clk or negedge tx_rst_n)
 if(!tx_rst_n)begin tb<=0;te<=0;end else begin tb<=tx_byte;te<=tx_enable;end
assign txd_i=tx_clk?tb[3:0]:tb[7:4];assign txctl_i=te;assign txc_i=tx_clk;
`else
EG_LOGIC_ODDR clock_out(.q(txc_i),.clk(tx_clk),.d0(1'b1),.d1(1'b0),.rst(!tx_rst_n));
EG_LOGIC_ODDR control_out(.q(txctl_i),.clk(tx_clk),.d0(tx_enable),.d1(tx_enable),.rst(!tx_rst_n));
for(i=0;i<4;i=i+1)begin:rgmii_data
 EG_LOGIC_ODDR data_out(.q(txd_i[i]),.clk(tx_clk),.d0(tx_byte[i]),.d1(tx_byte[i+4]),.rst(!tx_rst_n));
 EG_LOGIC_IDDR #(.PIPEMODE("PIPED")) data_in(.q0(rx_byte[i]),.q1(rx_byte[i+4]),.clk(phy_rxc),.d(phy_rxd[i]),.rst(!rx_rst_n));
end
EG_LOGIC_IDDR #(.PIPEMODE("PIPED")) control_in(.q0(ctl_rise),.q1(ctl_fall),.clk(phy_rxc),.d(phy_rxctl),.rst(!rx_rst_n));
`endif
assign rx_valid=ctl_rise;assign rx_error=ctl_rise^ctl_fall;
assign phy_txc=io_enable?txc_i:1'bz;
assign phy_txd=io_enable?txd_i:4'bzzzz;
assign phy_txctl=io_enable?txctl_i:1'bz;
endmodule
