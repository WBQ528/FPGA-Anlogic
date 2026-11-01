// 100Mb/s only. RX data is SDR; RXCTL still has distinct rise/fall meanings.
// The PHY/PCB must supply the audited RGMII clock skew. No guessed delay chain.
module bq_rgmii100_io(input tx_clk,input tx_rst_n,input rx_rst_n,input io_enable,
 input [3:0] tx_nibble,input tx_enable,
 input phy_rxc,input [3:0] phy_rxd,input phy_rxctl,
 output phy_txc,output [3:0] phy_txd,output phy_txctl,
 output [3:0] rx_nibble,output rx_valid,output rx_error);
 wire txc_i,txctl_i;wire [3:0] txd_i;
 wire [3:0] ignored_fall;
 wire ctl_rise,ctl_fall;
 genvar i;
`ifdef BQ_NET_SIM
 reg [3:0] r1,r2;reg cr1,cr2,cf1,cf2;
 always @(posedge phy_rxc or negedge rx_rst_n)
 if(!rx_rst_n)begin r1<=0;r2<=0;cr1<=0;cr2<=0;cf2<=0;end
 else begin r1<=phy_rxd;r2<=r1;cr1<=phy_rxctl;cr2<=cr1;cf2<=cf1;end
 always @(negedge phy_rxc or negedge rx_rst_n)
 if(!rx_rst_n)cf1<=0;else cf1<=phy_rxctl;
 assign rx_nibble=r2;assign ctl_rise=cr2;assign ctl_fall=cf2;
 // Functional replacement only. Physical test requires the vendor primitives.
 reg [3:0] txd_model;reg txctl_model;
 always @(posedge tx_clk or negedge tx_rst_n)
 if(!tx_rst_n)begin txd_model<=0;txctl_model<=0;end
 else begin txd_model<=tx_nibble;txctl_model<=tx_enable;end
 assign txd_i=txd_model;assign txctl_i=txctl_model;assign txc_i=tx_clk;
`else
 EG_LOGIC_ODDR clock_out(.q(txc_i),.clk(tx_clk),.d0(1'b1),.d1(1'b0),.rst(!tx_rst_n));
 EG_LOGIC_ODDR control_out(.q(txctl_i),.clk(tx_clk),.d0(tx_enable),.d1(tx_enable),.rst(!tx_rst_n));
 for(i=0;i<4;i=i+1)begin:rgmii_data
  EG_LOGIC_ODDR data_out(.q(txd_i[i]),.clk(tx_clk),.d0(tx_nibble[i]),.d1(tx_nibble[i]),.rst(!tx_rst_n));
  EG_LOGIC_IDDR #(.PIPEMODE("PIPED")) data_in(.q0(rx_nibble[i]),.q1(ignored_fall[i]),.clk(phy_rxc),.d(phy_rxd[i]),.rst(!rx_rst_n));
 end
 EG_LOGIC_IDDR #(.PIPEMODE("PIPED")) control_in(.q0(ctl_rise),.q1(ctl_fall),.clk(phy_rxc),.d(phy_rxctl),.rst(!rx_rst_n));
`endif
 assign rx_valid=ctl_rise;
 assign rx_error=ctl_rise^ctl_fall;
 // Physical outputs remain high-Z until the hardware enable is deliberately armed.
 assign phy_txc=io_enable?txc_i:1'bz;
 assign phy_txd=io_enable?txd_i:4'bzzzz;
 assign phy_txctl=io_enable?txctl_i:1'bz;
endmodule
