`timescale 1ns/1ps
module frame_fifo_write
#
(
	parameter MEM_DATA_BITS          = 32,
	parameter ADDR_BITS              = 21,
	parameter BURST_BITS             = 9,
	parameter BURST_SIZE             = 128,
	parameter WRITE_V_FLIP           = 1,      // 1: write image rows upside-down to cancel BMP bottom-up storage
	parameter FRAME_WIDTH            = 640,
	parameter FRAME_HEIGHT           = 480
)               
(
	input                            rst,                  
	input                            mem_clk,                    // external memory controller user interface clock
	input							 Sdr_init_done,
	input							 Sdr_init_ref_vld,
    input							 Sdr_busy,
	input							 App_rd_busy,
    output							 O_wr_busy,
	
	output 							 App_wr_en,
	output  [ADDR_BITS - 1:0]	 	App_wr_addr,
	/*
    output reg                       wr_burst_req,               // to external memory controller,send out a burst write request  
	output reg[BURST_BITS - 1:0]     wr_burst_len,               // to external memory controller,data length of the burst write request, not bytes 
	output reg[ADDR_BITS - 1:0]      wr_burst_addr,              // to external memory controller,base address of the burst write request 
	input                            wr_burst_data_req,          // from external memory controller,write data request ,before data 1 clock 
	input                            wr_burst_finish,            // from external memory controller,burst write finish
	*/
	input                            write_req,                  // data write module write request,keep '1' until read_req_ack = '1'
	output reg                       write_req_ack,              // data write module write request response
	output                           write_finish,               // data write module write request finish
	input[ADDR_BITS - 1:0]           write_addr_0,               // data write module write request base address 0, used when write_addr_index = 0
	input[ADDR_BITS - 1:0]           write_addr_1,               // data write module write request base address 1, used when write_addr_index = 1
	input[ADDR_BITS - 1:0]           write_addr_2,               // data write module write request base address 1, used when write_addr_index = 2
	input[ADDR_BITS - 1:0]           write_addr_3,               // data write module write request base address 1, used when write_addr_index = 3
	input[1:0]                       write_addr_index,           // select valid base address from write_addr_0 write_addr_1 write_addr_2 write_addr_3
	input[ADDR_BITS - 1:0]           write_len,                  // data write module write request data length
	output reg                       fifo_aclr,                  // to fifo asynchronous clear
	input[8:0]                      rdusedw                     // from fifo read used words
);

// Contract: 32-bit word addresses, lengths and bursts are multiples of four.
// Request/buffer/length remain stable through the request/ack handshake.
localparam IDLE=0, ACK=1, CHECK=2, ISSUE=3, DRAIN=4, DONE=5;
reg [2:0] state;
reg [2:0] req_sync;
reg [ADDR_BITS-1:0] remaining, address;
reg [BURST_BITS:0] target, issued, returned;
reg [4:0] drain_count;
reg [15:0] x_pos;
wire [ADDR_BITS-1:0] base_addr = (write_addr_index==0) ? write_addr_0 :
    (write_addr_index==1) ? write_addr_1 :
    (write_addr_index==2) ? write_addr_2 : write_addr_3;
wire [BURST_BITS:0] next_count = (remaining < BURST_SIZE) ? remaining : BURST_SIZE;
wire can_start = Sdr_init_done && !Sdr_init_ref_vld && !Sdr_busy && !App_rd_busy &&
    (rdusedw >= next_count);
assign App_wr_en = (state==ISSUE) && (issued < target);
assign App_wr_addr = address;
assign write_finish = (state==DONE);
assign O_wr_busy = (state==ISSUE) || (state==DRAIN) || (state==CHECK && remaining!=0 && can_start);
always @(posedge mem_clk or posedge rst) begin
 if(rst) req_sync<=0;
 else req_sync <= {req_sync[1:0], write_req};
end
always @(posedge mem_clk or posedge rst) begin
 if(rst) begin
  state<=IDLE; remaining<=0; address<=0; target<=0; issued<=0;
  returned<=0; drain_count<=0; x_pos<=0;
  write_req_ack<=0; fifo_aclr<=1;
 end else begin
  case(state)
   IDLE: begin
    fifo_aclr<=0;
    if(req_sync[2] && Sdr_init_done) state<=ACK;
   end
   ACK: begin
    write_req_ack<=1; fifo_aclr<=1;
    remaining<=write_len;
    address<=base_addr + (WRITE_V_FLIP ? (FRAME_HEIGHT-1)*FRAME_WIDTH : 0);
    x_pos<=0;
    if(!req_sync[2]) begin
     write_req_ack<=0; fifo_aclr<=0; state<=CHECK;
    end
   end
   CHECK: begin
    issued<=0; returned<=0; drain_count<=0;
    if(req_sync[2]) state<=ACK;
    else if(remaining==0) state<=DONE;
    else if(can_start) begin target<=next_count; state<=ISSUE; end
   end
   ISSUE: begin
    if(App_wr_en) begin
     issued<=issued+1'b1;
     if(WRITE_V_FLIP && x_pos==FRAME_WIDTH-1) begin address<=address-(2*FRAME_WIDTH-1); x_pos<=0; end else begin address<=address+1'b1; x_pos<=x_pos+1'b1; end
     if(issued+1'b1==target) state<=DRAIN;
    end
    
   end
   DRAIN: begin
    if(drain_count<16) drain_count<=drain_count+1'b1;
    if(drain_count==16 && !Sdr_busy) begin
     remaining<=remaining-target; state<=CHECK;
    end
   end
   DONE: state<=IDLE;
   default: begin state<=IDLE; write_req_ack<=0; fifo_aclr<=1; end
  endcase
 end
end
endmodule
