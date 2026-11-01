`timescale 1ns/1ps
// Dedicated gigabit transmit clock: 50MHz / 2 * 5 = 125MHz;
// 1GHz VCO / 8. Global feedback, zero phase. RX uses the PHY clock.
module bq_net_pll(input refclk,reset,output clk125,locked);
`ifdef BQ_NET_SIM
reg c=0;always #4 c=~c;
assign clk125=c;assign locked=!reset;
`else
wire raw;wire [3:0] unused_clocks;wire [7:0] unused_data;
EG_LOGIC_BUFG clock_buffer(.i(raw),.o(clk125));
EG_PHY_PLL #(.DPHASE_SOURCE("DISABLE"),.DYNCFG("DISABLE"),.FIN("50.000000"),
 .FEEDBK_MODE("NORMAL"),.FEEDBK_PATH("CLKC0_EXT"),.STDBY_ENABLE("DISABLE"),
 .PLLRST_ENA("ENABLE"),.SYNC_ENABLE("DISABLE"),.GMC_GAIN(4),.ICP_CURRENT(29),.KVCO(4),.LPF_CAPACITOR(1),.LPF_RESISTOR(2),
 .REFCLK_DIV(2),.FBCLK_DIV(5),.CLKC0_ENABLE("ENABLE"),.CLKC0_DIV(8),.CLKC0_CPHASE(7),.CLKC0_FPHASE(0),
 .CLKC1_ENABLE("DISABLE"),.CLKC2_ENABLE("DISABLE")) pll_inst(
 .refclk(refclk),.reset(reset),.stdby(1'b0),.extlock(locked),.load_reg(1'b0),
 .psclk(1'b0),.psdown(1'b0),.psstep(1'b0),.psclksel(3'b0),.psdone(),
 .dclk(1'b0),.dcs(1'b0),.dwe(1'b0),.di(8'b0),.daddr(6'b0),.do(unused_data),
 .fbclk(clk125),.clkc({unused_clocks,raw}));
`endif
endmodule
