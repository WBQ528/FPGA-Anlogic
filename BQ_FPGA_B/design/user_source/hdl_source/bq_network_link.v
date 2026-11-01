// public integration wrapper. rst is ACTIVE HIGH; clk is 50MHz.
// io_enable must come from a deliberate physical/UI arm after electrical review.
module bq_network_link #(parameter BOARD_ID=1,parameter CLK_HZ=50000000)(
 input clk,input rst,input io_enable,input [127:0] local_state,input local_state_commit,
 output [127:0] remote_state,output remote_update,output link_up,
 output peer_online,output stale,output phy_found,output [4:0] phy_addr,
 output [31:0] phy_id,output [31:0] tx_count,output [31:0] rx_count,
 output [31:0] error_count,output [31:0] retry_count,output mdio_fault,
 input phy_rxc,input [3:0] phy_rxd,input phy_rxctl,
 output rx_delay_enabled,output [15:0] bad_frame_count,output [15:0] overflow_count,output [31:0] rejected_count,
 output phy_txc,output [3:0] phy_txd,output phy_txctl,output phy_mdc,inout phy_mdio);
 localparam [47:0] LOCAL_MAC=(BOARD_ID==1)?48'h024251000001:48'h024251000002;
 localparam [47:0] PEER_MAC=(BOARD_ID==1)?48'h024251000002:48'h024251000001;
 wire tx_clk,tx_locked,core_rst_n,tx_rst_n,rx_rst_n;
 bq_net_pll net_pll(.refclk(clk),.reset(rst),.clk125(tx_clk),.locked(tx_locked));
 bq_reset_sync reset_core(.clk(clk),.arst_n(!rst && tx_locked),.rst_n(core_rst_n));
 bq_reset_sync reset_tx(.clk(tx_clk),.arst_n(!rst && tx_locked),.rst_n(tx_rst_n));
 bq_reset_sync reset_rx(.clk(phy_rxc),.arst_n(!rst && tx_locked),.rst_n(rx_rst_n));
 bq_phy_config #(.CLK_HZ(CLK_HZ),.GIGABIT(1),.AUTO_RX_TRAIN(1)) phy(.clk(clk),.rst_n(core_rst_n),.enable(io_enable),
 .mdc(phy_mdc),.mdio(phy_mdio),.phy_found(phy_found),.phy_addr(phy_addr),
 .phy_id(phy_id),.link_100_full(link_up),.mdio_fault(mdio_fault),.rx_progress(remote_update),.rx_delay_enabled(rx_delay_enabled));
 wire [367:0] tx_packet,tx_bundle,rx_bundle,rx_packet;
 wire tx_valid,tx_ready,tx_bundle_valid,tx_bundle_ready;
 wire rx_valid,rx_ready,rx_bundle_valid,rx_bundle_ready;
 wire [7:0] tx_byte,rx_byte;
 wire tx_enable,rx_dv,rx_er,mac_sent,mac_bad,mac_overflow;
 wire [31:0] protocol_reject;
 reg bad_toggle,overflow_toggle;
 (* ASYNC_REG="TRUE" *) reg [2:0] bad_sync,overflow_sync;
 reg [15:0] mac_bad_count,mac_overflow_count;
 always @(posedge phy_rxc or negedge rx_rst_n)
 if(!rx_rst_n)begin bad_toggle<=0;overflow_toggle<=0;end
 else begin if(mac_bad)bad_toggle<=~bad_toggle;if(mac_overflow)overflow_toggle<=~overflow_toggle;end
 always @(posedge clk or negedge core_rst_n)
 if(!core_rst_n)begin bad_sync<=0;overflow_sync<=0;mac_bad_count<=0;mac_overflow_count<=0;end
 else begin
  bad_sync<={bad_sync[1:0],bad_toggle};overflow_sync<={overflow_sync[1:0],overflow_toggle};
  if(bad_sync[2]^bad_sync[1])mac_bad_count<=mac_bad_count+1'b1;
  if(overflow_sync[2]^overflow_sync[1])mac_overflow_count<=mac_overflow_count+1'b1;
 end
 assign bad_frame_count=mac_bad_count;assign overflow_count=mac_overflow_count;assign rejected_count=protocol_reject;
 assign error_count=protocol_reject+{16'd0,mac_bad_count}+{16'd0,mac_overflow_count};
 bq_state_link #(.BOARD_ID(BOARD_ID),.CLK_HZ(CLK_HZ)) state_link(
 .clk(clk),.rst_n(core_rst_n),.physical_link(link_up&&io_enable),
 .local_state(local_state),.local_state_commit(local_state_commit),.remote_state(remote_state),
 .remote_update(remote_update),.peer_online(peer_online),.stale(stale),
 .tx_packet(tx_packet),.tx_valid(tx_valid),.tx_ready(tx_ready),
 .rx_packet(rx_packet),.rx_valid(rx_valid),.rx_ready(rx_ready),
 .tx_count(tx_count),.rx_count(rx_count),.reject_count(protocol_reject),.retry_count(retry_count));
 bq_cdc_mailbox #(.WIDTH(368),.SOURCE_HOLDS(1),.REGISTER_OUTPUT(0)) tx_mailbox(.src_clk(clk),.src_rst_n(core_rst_n),
 .src_data(tx_packet),.src_valid(tx_valid),.src_ready(tx_ready),
 .dst_clk(tx_clk),.dst_rst_n(tx_rst_n),.dst_data(tx_bundle),.dst_valid(tx_bundle_valid),.dst_ready(tx_bundle_ready));
 bq_mac_tx1000 #(.LOCAL_MAC(LOCAL_MAC),.PEER_MAC(PEER_MAC)) mac_tx(
 .clk(tx_clk),.rst_n(tx_rst_n),.packet(tx_bundle),.valid(tx_bundle_valid),.ready(tx_bundle_ready),
 .txd(tx_byte),.tx_en(tx_enable),.sent(mac_sent));
 bq_rgmii1000_io rgmii(.tx_clk(tx_clk),.tx_rst_n(tx_rst_n),.rx_rst_n(rx_rst_n),.io_enable(io_enable),
 .tx_byte(tx_byte),.tx_enable(tx_enable),.phy_rxc(phy_rxc),.phy_rxd(phy_rxd),.phy_rxctl(phy_rxctl),
 .phy_txc(phy_txc),.phy_txd(phy_txd),.phy_txctl(phy_txctl),
 .rx_byte(rx_byte),.rx_valid(rx_dv),.rx_error(rx_er));
 bq_mac_rx1000 #(.LOCAL_MAC(LOCAL_MAC),.PEER_MAC(PEER_MAC)) mac_rx(
 .clk(phy_rxc),.rst_n(rx_rst_n),.rxd(rx_byte),.rx_dv(rx_dv),.rx_er(rx_er),
 .packet(rx_bundle),.valid(rx_bundle_valid),.ready(rx_bundle_ready),.bad_frame(mac_bad),.overflow(mac_overflow));
 bq_cdc_mailbox #(.WIDTH(368),.SOURCE_HOLDS(1),.REGISTER_OUTPUT(0)) rx_mailbox(.src_clk(phy_rxc),.src_rst_n(rx_rst_n),
 .src_data(rx_bundle),.src_valid(rx_bundle_valid),.src_ready(rx_bundle_ready),
 .dst_clk(clk),.dst_rst_n(core_rst_n),.dst_data(rx_packet),.dst_valid(rx_valid),.dst_ready(rx_ready));
endmodule
