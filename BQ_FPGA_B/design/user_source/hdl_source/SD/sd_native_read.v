// Read-only 3.3V native SD: 400kHz identification / 25MHz four-bit data.
// No partial sector is published before command and all four CRCs pass.
// SD v2 cards (SDSC/SDHC/SDXC), FAT interpretation belongs to the consumer.
module sd_native_read #(
 parameter integer SLOW_HALF=125, FAST_HALF=2, POWER_CYCLES=100000,
 parameter integer TIMEOUT_CYCLES=30000000,
 parameter integer IDLE_COUNTER_HOLD=1,
 parameter integer SECTOR_READ_ENABLE=1,
 parameter integer ENABLE_PREFETCH=1, MAX_BURST=16
)(input clk,rst,output reg sd_clk,inout sd_cmd,input [3:0] sd_dat,
 output reg initialized,input read_req,input [31:0] read_addr,input [4:0] read_count,
 output reg [7:0] read_data,output reg read_valid,read_end,
 output reg [3:0] error_code,output reg [15:0] retries);
reg [7:0] divider;
reg fast;
reg divider_zero;
wire rise_tick=divider_zero && !sd_clk;
wire fall_tick=divider_zero && sd_clk;
always @(posedge clk or posedge rst)begin
 if(rst)begin divider<=SLOW_HALF-1;sd_clk<=0;divider_zero<=SLOW_HALF==1;end
 else if(divider_zero)begin
  sd_clk<=~sd_clk;divider<=(fast?FAST_HALF:SLOW_HALF)-1;
  divider_zero<=fast ? FAST_HALF==1:SLOW_HALF==1;
 end else begin divider<=divider-1'b1;divider_zero<=divider==1;end
end
// Capture the pins one host clock AFTER the SD rising edge. The qualifier must
// include the input-register latency too: the old single-stage tick consumed
// pins captured ON that edge (12ns after launch on A). Unequal 5..14ns DAT
// delays then mixed adjacent nibbles even though a common-delay model passed.
// At high speed this captures just before the next launched data can return.
reg rise_capture,sample_tick,cmd_sample;reg [3:0] dat_sample;
always @(posedge clk or posedge rst)begin
 if(rst)begin rise_capture<=0;sample_tick<=0;cmd_sample<=1;dat_sample<=15;end
 else begin rise_capture<=rise_tick;sample_tick<=rise_capture;cmd_sample<=sd_cmd;dat_sample<=sd_dat;end
end
wire cmd_out,cmd_oe,cmd_done,cmd_failed,cmd_busy;
reg cmd_start;reg [5:0] cmd_index;reg [31:0] cmd_arg;reg [1:0] cmd_kind;
wire [31:0] response;
assign sd_cmd=cmd_oe?cmd_out:1'bz;
sd_native_command command(.clk(clk),.rst(rst),.rise_tick(sample_tick),.fall_tick(fall_tick),
 .start(cmd_start),.index(cmd_index),.argument(cmd_arg),.response_type(cmd_kind),
 .cmd_in(cmd_sample),.cmd_out(cmd_out),.cmd_oe(cmd_oe),.busy(cmd_busy),
 .done(cmd_done),.failed(cmd_failed),.response(response));
function [15:0] crc16;
 input [15:0] c;input b;
 begin crc16={c[14:0],1'b0} ^ ((c[15]^b)?16'h1021:16'h0);end
endfunction
reg arm_data;
reg [2:0] data_state;
reg [10:0] nibble_count;
reg [3:0] high_nibble;
reg [15:0] crc0,crc1,crc2,crc3;
reg data_done,data_bad;
// Up to 16 sectors, CRC-verified as one bounded CMD18 transaction.
// The FAT reader limits lookahead to the current allocated cluster.
reg [7:0] sector[0:MAX_BURST*512-1];
localparam integer CACHE_BLOCK_BITS=$clog2(MAX_BURST);
reg [3:0] receive_block,drain_block;
reg [4:0] burst_count,cache_count;
reg cache_valid,burst_bad,stop_failed;
reg [31:0] cache_base;
reg cache_hit;
// Evaluate the incoming sector while latching it in IDLE. The following
// CACHE_LOOKUP uses this registered predicate; cache ownership is unchanged.
always @(posedge clk or posedge rst)
 if(rst)cache_hit<=0;
 else if(state==IDLE && read_req)cache_hit<=cache_valid && read_addr>=cache_base && read_addr-cache_base<{27'd0,cache_count};
wire [4:0] requested_count=(ENABLE_PREFETCH && read_count>=1 && read_count<=16)?(read_count>MAX_BURST?MAX_BURST:read_count):5'd1;
reg [8:0] out_address;
reg [7:0] ram_q;
wire sector_read_enable=!SECTOR_READ_ENABLE || state==DRAIN_WAIT;
always @(posedge clk)begin
 if(sector_read_enable)ram_q<=sector[{drain_block[CACHE_BLOCK_BITS-1:0],out_address}];
 if(data_state==2 && sample_tick && nibble_count[0])
  sector[{receive_block[CACHE_BLOCK_BITS-1:0],nibble_count[9:1]}]<={high_nibble,dat_sample};
end
always @(posedge clk or posedge rst)begin
 if(rst)begin data_state<=0;nibble_count<=0;high_nibble<=0;
  crc0<=0;crc1<=0;crc2<=0;crc3<=0;data_done<=0;data_bad<=0;receive_block<=0;end
 else if(arm_data)begin data_state<=1;data_done<=0;data_bad<=0;nibble_count<=0;receive_block<=0;
  crc0<=0;crc1<=0;crc2<=0;crc3<=0;end
 else if(sample_tick)case(data_state)
  1:if(dat_sample==0)begin data_state<=2;nibble_count<=0;end
  2:begin
   high_nibble<=dat_sample;nibble_count<=nibble_count+1'b1;
   crc0<=crc16(crc0,dat_sample[0]);crc1<=crc16(crc1,dat_sample[1]);
   crc2<=crc16(crc2,dat_sample[2]);crc3<=crc16(crc3,dat_sample[3]);
   if(nibble_count==1023)begin data_state<=3;nibble_count<=0;end
  end
  3:begin
   crc0<=crc16(crc0,dat_sample[0]);crc1<=crc16(crc1,dat_sample[1]);
   crc2<=crc16(crc2,dat_sample[2]);crc3<=crc16(crc3,dat_sample[3]);
   if(nibble_count==15)data_state<=4;else nibble_count<=nibble_count+1'b1;
  end
  4:begin
   data_bad<=data_bad || dat_sample!=15 || (crc0|crc1|crc2|crc3)!=0;
   if({1'b0,receive_block}+5'd1<burst_count)begin
    receive_block<=receive_block+1'b1;data_state<=1;nibble_count<=0;
    crc0<=0;crc1<=0;crc2<=0;crc3<=0;
   end else begin data_done<=1;data_state<=0;end
  end
 endcase
end
localparam POWER=0,ISSUE=1,RESPONSE=2,BUSY_WAIT=3,IDLE=4,DATA_WAIT=5,
 DRAIN_WAIT=6,DRAIN_OUT=7,FINISH=8,RETRY=9,FAIL=10,WAIT_DROP=11,STOP_BUSY=12,CACHE_LOOKUP=13;
reg [3:0] state;
reg [3:0] init_step;
reg [26:0] timer;reg timeout_hit,power_hit;
reg [15:0] rca;
reg high_capacity;
reg [31:0] address;
reg [1:0] attempt;
reg [11:0] init_loops;
reg init_exhausted;
always @(posedge clk) init_exhausted<=init_loops==12'd4095;
// The command engine holds response for eight SD clocks in GAP before done.
// Register R1 validation there instead of cascading a wide mask through the
// initialization/read/stop state decisions on the done clock.
reg status_error,echo_error,voltage_error,rca_error;
always @(posedge clk or posedge rst)begin
 if(rst)begin status_error<=0;echo_error<=0;voltage_error<=0;rca_error<=0;end
 else begin
  status_error<=(response & 32'hfdffe008)!=0;
  echo_error<=response[11:0]!=12'h1aa;
  voltage_error<=(response & 32'h00ff8000)==0;
  rca_error<=response[15:13]!=0 || response[31:16]==0;
 end
end
always @(posedge clk or posedge rst)begin
 if(rst)begin state<=POWER;timer<=0;timeout_hit<=0;power_hit<=0;fast<=0;initialized<=0;error_code<=0;retries<=0;
  cmd_start<=0;cmd_index<=0;cmd_arg<=0;cmd_kind<=0;init_step<=0;
  rca<=0;high_capacity<=0;address<=0;attempt<=0;init_loops<=0;
  burst_count<=1;cache_count<=0;cache_valid<=0;cache_base<=0;drain_block<=0;burst_bad<=0;stop_failed<=0;
  arm_data<=0;out_address<=0;read_data<=0;read_valid<=0;read_end<=0;end
 else begin
  cmd_start<=0;arm_data<=0;read_valid<=0;read_end<=0;
  // Predict registered thresholds for the next counter value. Explicit
  // timer resets also clear both predicates, preventing stale timeouts.
  timeout_hit<=timer>=TIMEOUT_CYCLES-1;power_hit<=timer>=POWER_CYCLES-1;
  // No deadline exists between transactions. Hold the watchdog at zero while
  // idle; ISSUE still starts each real command's timeout at zero as before.
  // The SD pin clock, HDMI timing and SDRAM refresh are not gated.
  if(IDLE_COUNTER_HOLD && (state==IDLE || state==WAIT_DROP))begin timer<=0;timeout_hit<=0;power_hit<=0;end
  else if(!timeout_hit)timer<=timer+1'b1;
  case(state)
   POWER:if(power_hit)begin init_step<=0;state<=ISSUE;timer<=0;timeout_hit<=0;power_hit<=0;end
   ISSUE:if(!cmd_busy)begin
    cmd_start<=1;state<=RESPONSE;timer<=0;timeout_hit<=0;power_hit<=0;
    case(init_step)
     0:begin cmd_index<=0;cmd_arg<=0;cmd_kind<=0;end
     1:begin cmd_index<=8;cmd_arg<=32'h1aa;cmd_kind<=1;end
     2:begin cmd_index<=55;cmd_arg<=0;cmd_kind<=1;end
     3:begin cmd_index<=41;cmd_arg<=32'h40ff8000;cmd_kind<=3;end
     4:begin cmd_index<=2;cmd_arg<=0;cmd_kind<=2;end
     5:begin cmd_index<=3;cmd_arg<=0;cmd_kind<=1;end
     6:begin cmd_index<=7;cmd_arg<={rca,16'd0};cmd_kind<=1;end
     7:begin cmd_index<=55;cmd_arg<={rca,16'd0};cmd_kind<=1;end
     8:begin cmd_index<=6;cmd_arg<=2;cmd_kind<=1;end
     9:begin cmd_index<=16;cmd_arg<=512;cmd_kind<=1;end
     10:begin cmd_index<=burst_count>1?18:17;cmd_arg<=high_capacity?address:{address[22:0],9'd0};cmd_kind<=1;arm_data<=1;end
     11:begin cmd_index<=12;cmd_arg<=0;cmd_kind<=1;end
     default:begin cmd_index<=0;cmd_arg<=0;cmd_kind<=0;end
    endcase
   end
   RESPONSE:if(cmd_done)begin
    if(cmd_failed)begin
     if(init_step==10)begin
      if(burst_count>1)begin burst_bad<=1;init_step<=11;state<=ISSUE;end else state<=RETRY;
     end else if(init_step==11)begin state<=FAIL;error_code<=9;end else begin state<=FAIL;error_code<=1;end
    end else case(init_step)
     0:begin init_step<=1;state<=ISSUE;end
     1:if(echo_error)begin state<=FAIL;error_code<=2;end
       else begin init_step<=2;state<=ISSUE;end
     2,7:if(status_error || !response[5])begin state<=FAIL;error_code<=3;end
       else begin init_step<=init_step+1'b1;state<=ISSUE;end
     3:if(!response[31])begin
       if(init_exhausted)begin state<=FAIL;error_code<=4;end
       else begin init_loops<=init_loops+1'b1;init_step<=2;state<=ISSUE;end
      end else if(voltage_error)begin state<=FAIL;error_code<=4;end
      else begin high_capacity<=response[30];init_step<=4;state<=ISSUE;end
     4:begin init_step<=5;state<=ISSUE;end
     5:if(rca_error)begin state<=FAIL;error_code<=5;end
       else begin rca<=response[31:16];init_step<=6;state<=ISSUE;end
     6:if(status_error)begin state<=FAIL;error_code<=6;end
       else begin state<=BUSY_WAIT;timer<=0;timeout_hit<=0;power_hit<=0;end
     8:if(status_error)begin state<=FAIL;error_code<=7;end
       else if(!high_capacity)begin init_step<=9;state<=ISSUE;end
       else begin initialized<=1;fast<=1;state<=IDLE;end
     9:if(status_error)begin state<=FAIL;error_code<=7;end
       else begin initialized<=1;fast<=1;state<=IDLE;end
     10:if(status_error)begin
      if(burst_count>1)begin burst_bad<=1;init_step<=11;state<=ISSUE;end else state<=RETRY;
     end else state<=DATA_WAIT;
     11:begin stop_failed<=status_error;state<=STOP_BUSY;timer<=0;timeout_hit<=0;power_hit<=0;end
     default:begin state<=FAIL;error_code<=15;end
    endcase
   end else if(timeout_hit)begin state<=FAIL;error_code<=8;end
   BUSY_WAIT:if(sample_tick && dat_sample[0])begin init_step<=7;state<=ISSUE;end
     else if(timeout_hit)begin state<=FAIL;error_code<=8;end
   IDLE:if(read_req)begin
    address<=read_addr;burst_count<=requested_count;attempt<=0;state<=CACHE_LOOKUP;
   end
   CACHE_LOOKUP:begin
    if(cache_hit)begin drain_block<=address-cache_base;out_address<=0;state<=DRAIN_WAIT;end
    else begin init_step<=10;state<=ISSUE;cache_valid<=0;burst_bad<=0;drain_block<=0;end
   end
   DATA_WAIT:if(data_done)begin
     if(burst_count>1)begin burst_bad<=data_bad;init_step<=11;state<=ISSUE;end
     else if(data_bad)state<=RETRY;else begin out_address<=0;state<=DRAIN_WAIT;end
    end else if(timeout_hit)begin
     if(burst_count>1)begin burst_bad<=1;init_step<=11;state<=ISSUE;end else state<=RETRY;
    end
   STOP_BUSY:if(sample_tick && dat_sample[0])begin
    if(stop_failed)begin state<=FAIL;error_code<=9;end
    else if(burst_bad)state<=RETRY;
    else begin cache_valid<=1;cache_base<=address;cache_count<=burst_count;drain_block<=0;out_address<=0;state<=DRAIN_WAIT;end
   end else if(timeout_hit)begin state<=FAIL;error_code<=8;end
   DRAIN_WAIT:state<=DRAIN_OUT;
   DRAIN_OUT:begin read_data<=ram_q;read_valid<=1;
    if(out_address==511)state<=FINISH;
    else begin out_address<=out_address+1'b1;state<=DRAIN_WAIT;end
   end
   FINISH:begin read_end<=1;state<=WAIT_DROP;end
   WAIT_DROP:if(!read_req)state<=IDLE;
   RETRY:if(!cmd_busy && (data_state==0 || burst_count>1 || timeout_hit))begin
    if(attempt==2)begin state<=FAIL;error_code<=9;end
    else begin attempt<=attempt+1'b1;retries<=retries+1'b1;state<=ISSUE;init_step<=10;end
   end
   FAIL:initialized<=0;
   default:begin state<=FAIL;error_code<=15;end
  endcase
 end
end
endmodule
