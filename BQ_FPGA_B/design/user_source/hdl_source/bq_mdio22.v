// Clause 22 management, 1 MHz MDC with 50 MHz clk / divider 25.
// MDIO is OPEN DRAIN: never actively drive a high level into PHY 2.5V rail.
module bq_mdio22 #(parameter MDC_HALF=25)(
 input clk,input rst_n,input start,input write_op,input [4:0] phy_addr,
 input [4:0] reg_addr,input [15:0] write_data,
 output reg busy,output reg done,output reg [15:0] read_data,
 output reg ta_error,output reg mdc,inout mdio);
 reg [63:0] frame;
 reg [5:0] bit_index;
 localparam DIV_BITS=(MDC_HALF<=2)?1:$clog2(MDC_HALF);
 reg [DIV_BITS-1:0] divider;
 reg is_write;
 wire drive=busy&&(is_write||bit_index>=18);
 assign mdio=(drive&&!frame[bit_index])?1'b0:1'bz;
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin frame<=0;bit_index<=0;divider<=0;is_write<=0;
 busy<=0;done<=0;read_data<=0;ta_error<=0;mdc<=0;end
 else begin
  done<=0;
  if(start&&!busy)begin
   frame<={32'hffffffff,2'b01,(write_op?2'b01:2'b10),phy_addr,reg_addr,2'b10,write_data};
   bit_index<=63;divider<=0;is_write<=write_op;busy<=1;
   read_data<=0;ta_error<=0;mdc<=0;
  end else if(busy)begin
   if(divider==MDC_HALF-1)begin
    divider<=0;mdc<=~mdc;
    if(!mdc)begin
     if(!is_write&&bit_index==16)ta_error<=(mdio!==1'b0);
     if(!is_write&&bit_index<16)read_data<={read_data[14:0],mdio};
    end else begin
     if(bit_index==0)begin busy<=0;done<=1;mdc<=0;end
     else bit_index<=bit_index-1'b1;
    end
   end else divider<=divider+1'b1;
  end
 end
endmodule

// RTL8211E (001c:c915) only. Restore page, verify RGMII-ID and 100FD.
// MAC forwards an edge-aligned clock: PHY supplies both 2 ns delay paths.
// Extension page 0xa4, reg 0x1c bits 13:11 follow RTL8211E RGMII-ID.
// Preserve all other bits; wrong PHY model or failed readback cannot enable MAC.
module bq_phy_config #(parameter CLK_HZ=50000000,parameter GIGABIT=0,parameter AUTO_RX_TRAIN=0)(
 input clk,input rst_n,input enable,output mdc,inout mdio,
 output reg phy_found,output reg [4:0] phy_addr,
 output reg [31:0] phy_id,output reg link_100_full,output reg mdio_fault,input rx_progress,output reg rx_delay_enabled);
 reg start,write_op;
 reg [4:0] reg_addr,state;
 reg [15:0] write_data,delay_value;
 wire busy,done,ta_error;wire [15:0] read_data;
 localparam WAIT_BITS=(CLK_HZ/5<=2)?1:$clog2(CLK_HZ/5);
 reg [WAIT_BITS-1:0] wait_count;
 reg [1:0] poll_errors;
 localparam WAIT=0,PAGE0=1,ID1=2,ID2=3,PAGE7=4,EXT=5,DELAY_READ=6,
 DELAY_WRITE=7,DELAY_VERIFY=8,RESTORE=9,ADV_WRITE=10,ADV_READ=11,
 GIGA_WRITE=12,GIGA_READ=13,AN_WRITE=14,AN_READ=15,POLL_WAIT=16,POLL=17,
 SCAN_NEXT=18,RECOVER=19,TRAIN_PAGE=20,TRAIN_EXT=21,TRAIN_READ=22,TRAIN_WRITE=23,TRAIN_VERIFY=24,TRAIN_RESTORE=25;
 localparam TRAIN_CYCLES=CLK_HZ*3;
 reg [$clog2(TRAIN_CYCLES+1)-1:0] rx_watchdog;
 reg train_request;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin rx_watchdog<=0;train_request<=0;end
  else if(!AUTO_RX_TRAIN || !enable || !link_100_full || rx_progress || state==TRAIN_PAGE)begin rx_watchdog<=0;train_request<=0;end
  else if(rx_watchdog==TRAIN_CYCLES-1)begin train_request<=1;end
  else rx_watchdog<=rx_watchdog+1'b1;
 end
 bq_mdio22 md(.clk(clk),.rst_n(rst_n&&enable),.start(start),.write_op(write_op),
 .phy_addr(phy_addr),.reg_addr(reg_addr),.write_data(write_data),.busy(busy),
 .done(done),.read_data(read_data),.ta_error(ta_error),.mdc(mdc),.mdio(mdio));
 task issue;
 input wr;input [4:0] addr;input [15:0] value;input [4:0] next;
 begin write_op<=wr;reg_addr<=addr;write_data<=value;start<=1;state<=next;end
 endtask
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin start<=0;write_op<=0;reg_addr<=0;write_data<=0;delay_value<=0;
 state<=WAIT;wait_count<=0;phy_found<=0;phy_addr<=0;phy_id<=0;
 link_100_full<=0;mdio_fault<=0;poll_errors<=0;rx_delay_enabled<=1;end
 else begin
  start<=0;
  if(!enable)begin state<=WAIT;wait_count<=0;phy_found<=0;link_100_full<=0;
   phy_addr<=0;phy_id<=0;mdio_fault<=0;poll_errors<=0;end
  else case(state)
  WAIT:if(wait_count==CLK_HZ/5-1)begin wait_count<=0;issue(1,31,0,PAGE0);end
    else wait_count<=wait_count+1'b1;
  PAGE0:if(done)issue(0,2,0,ID1);
  ID1:if(done)begin
    if(!ta_error&&read_data==16'h001c)begin phy_id[31:16]<=read_data;issue(0,3,0,ID2);end
    else state<=SCAN_NEXT;
   end
  ID2:if(done)begin
    if(!ta_error&&read_data==16'hc915)begin
     phy_id[15:0]<=read_data;issue(1,31,7,PAGE7);
    end else state<=SCAN_NEXT;
   end
  PAGE7:if(done)issue(1,30,16'h00a4,EXT);
  EXT:if(done)issue(0,28,0,DELAY_READ);
  DELAY_READ:if(done)begin
   if(ta_error)state<=RECOVER;
   else begin delay_value<=read_data|16'h3800;issue(1,28,read_data|16'h3800,DELAY_WRITE);end
  end
  DELAY_WRITE:if(done)issue(0,28,0,DELAY_VERIFY);
  DELAY_VERIFY:if(done)begin
   if(ta_error||read_data!=delay_value)state<=RECOVER;
   else begin rx_delay_enabled<=delay_value[11];issue(1,31,0,RESTORE);end
  end
  RESTORE:if(done)issue(1,4,GIGABIT?16'h0001:16'h0101,ADV_WRITE);
  ADV_WRITE:if(done)issue(0,4,0,ADV_READ);
  ADV_READ:if(done)begin
   if(ta_error||read_data!=(GIGABIT?16'h0001:16'h0101))state<=RECOVER;
   else issue(1,9,GIGABIT?16'h0200:16'h0000,GIGA_WRITE);
  end
  GIGA_WRITE:if(done)issue(0,9,0,GIGA_READ);
  GIGA_READ:if(done)begin
   if(ta_error||read_data!=(GIGABIT?16'h0200:16'h0000))state<=RECOVER;
   else issue(1,0,GIGABIT?16'h1340:16'h3300,AN_WRITE);
  end
  AN_WRITE:if(done)issue(0,0,0,AN_READ);
  AN_READ:if(done)begin
   // AN restart is self-clearing; speed/autoneg/full-duplex must read back.
   if(ta_error||(read_data&16'h3140)!=(GIGABIT?16'h1140:16'h3100))state<=RECOVER;
   else begin phy_found<=1;mdio_fault<=0;poll_errors<=0;wait_count<=0;state<=POLL_WAIT;end
  end
  POLL_WAIT:if(AUTO_RX_TRAIN && train_request)begin wait_count<=0;issue(1,31,7,TRAIN_PAGE);end
    else if(wait_count==CLK_HZ/10-1)begin wait_count<=0;issue(0,17,0,POLL);end
    else wait_count<=wait_count+1'b1;
  POLL:if(done)begin
   link_100_full<=!ta_error&&(read_data[15:14]==(GIGABIT?2'b10:2'b01))&&read_data[13]&&read_data[11]&&read_data[10];
   mdio_fault<=ta_error;
   if(ta_error)begin
    if(poll_errors==2)state<=RECOVER;
    else begin poll_errors<=poll_errors+1'b1;state<=POLL_WAIT;end
   end else begin poll_errors<=0;state<=POLL_WAIT;end
  end
  // A routed FPGA input clock can have a different insertion delay from the
  // data pins. Try the two documented RTL8211E RX skew settings only after
  // three seconds without a CRC/protocol-valid peer packet. TX delay remains
  // enabled. A valid received state freezes training; no bad frame executes.
  TRAIN_PAGE:if(done)issue(1,30,16'h00a4,TRAIN_EXT);
  TRAIN_EXT:if(done)issue(0,28,0,TRAIN_READ);
  TRAIN_READ:if(done)begin
   if(ta_error)state<=RECOVER;
   else begin delay_value<=read_data^16'h0800;issue(1,28,read_data^16'h0800,TRAIN_WRITE);end
  end
  TRAIN_WRITE:if(done)issue(0,28,0,TRAIN_VERIFY);
  TRAIN_VERIFY:if(done)begin
   if(ta_error || read_data!=delay_value)state<=RECOVER;
   else begin rx_delay_enabled<=delay_value[11];issue(1,31,0,TRAIN_RESTORE);end
  end
  TRAIN_RESTORE:if(done)begin wait_count<=0;state<=POLL_WAIT;end
  SCAN_NEXT:begin
   phy_addr<=phy_addr+1'b1;phy_id<=0;phy_found<=0;link_100_full<=0;
   if(phy_addr==31)begin mdio_fault<=1;wait_count<=0;state<=WAIT;end
   else issue(1,31,0,PAGE0);
  end
  RECOVER:begin phy_found<=0;link_100_full<=0;mdio_fault<=1;phy_id<=0;
   wait_count<=0;poll_errors<=0;state<=WAIT;end
  default:state<=RECOVER;
  endcase
 end
endmodule
