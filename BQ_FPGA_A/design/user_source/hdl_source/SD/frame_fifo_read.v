`timescale 1ns/1ps
module frame_fifo_read
#
(
	parameter MEM_DATA_BITS          = 32,
	parameter ADDR_BITS              = 21,
	parameter BURST_BITS             = 9,
	parameter FIFO_DEPTH             = 512,
	parameter BURST_SIZE             = 128
)               
(
	input                            rst,                  
	input                            mem_clk,                    // external memory controller user interface clock
	input							 Sdr_init_done,
	input							 Sdr_init_ref_vld,
    input							 Sdr_busy,
    input							 Sdr_rd_en,
	input							 App_wr_busy,
    output							 O_rd_busy,
	/*
    output reg                       rd_burst_req,               // to external memory controller,send out a burst read request  
	output reg[BURST_BITS - 1:0]     rd_burst_len,               // to external memory controller,data length of the burst read request, not bytes 
	output reg[ADDR_BITS - 1:0]      rd_burst_addr,              // to external memory controller,base address of the burst read request
	input                            rd_burst_data_valid,        // from external memory controller,read request data valid    
	input                            rd_burst_finish,            // from external memory controller,burst read finish
	*/
	output 							 App_rd_en,
	output  [ADDR_BITS - 1:0]		 App_rd_addr,
	
	input                            read_req,                   // data read module read request,keep '1' until read_req_ack = '1'
	output reg                       read_req_ack,               // data read module read request response
	output                           read_finish,                // data read module read request finish
	input[ADDR_BITS - 1:0]           read_addr_0,                // data read module read request base address 0, used when read_addr_index = 0
	input[ADDR_BITS - 1:0]           read_addr_1,                // data read module read request base address 1, used when read_addr_index = 1
	input[ADDR_BITS - 1:0]           read_addr_2,                // data read module read request base address 1, used when read_addr_index = 2
	input[ADDR_BITS - 1:0]           read_addr_3,                // data read module read request base address 1, used when read_addr_index = 3
	input[1:0]                       read_addr_index,            // select valid base address from read_addr_0 read_addr_1 read_addr_2 read_addr_3
	input[ADDR_BITS - 1:0]           read_len,                   // data read module read request data length
	output reg                       fifo_aclr,                  // to fifo asynchronous clear
	input[8:0]                      wrusedw                     // from fifo write used words

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
wire [ADDR_BITS-1:0] base_addr = (read_addr_index==0) ? read_addr_0 :
    (read_addr_index==1) ? read_addr_1 :
    (read_addr_index==2) ? read_addr_2 : read_addr_3;
wire [BURST_BITS:0] next_count = (remaining < BURST_SIZE) ? remaining : BURST_SIZE;
wire can_start = Sdr_init_done && !Sdr_init_ref_vld && !Sdr_busy && !App_wr_busy &&
    (wrusedw + next_count <= FIFO_DEPTH-1);
assign App_rd_en = (state==ISSUE) && (issued < target);
assign App_rd_addr = address;
assign read_finish = (state==DONE);
assign O_rd_busy = (state==ISSUE) || (state==DRAIN);
always @(posedge mem_clk or posedge rst) begin
 if(rst) req_sync<=0;
 else req_sync <= {req_sync[1:0], read_req};
end
always @(posedge mem_clk or posedge rst) begin
 if(rst) begin
  state<=IDLE; remaining<=0; address<=0; target<=0; issued<=0;
  returned<=0; drain_count<=0; x_pos<=0;
  read_req_ack<=0; fifo_aclr<=1;
 end else begin
  case(state)
   IDLE: begin
    fifo_aclr<=0;
    if(req_sync[2] && Sdr_init_done) state<=ACK;
   end
   ACK: begin
    read_req_ack<=1; fifo_aclr<=1;
    remaining<=read_len;
    address<=base_addr;
    x_pos<=0;
    if(!req_sync[2]) begin
     read_req_ack<=0; fifo_aclr<=0; state<=CHECK;
    end
   end
   CHECK: begin
    issued<=0; returned<=0; drain_count<=0;
    if(req_sync[2]) state<=ACK;
    else if(remaining==0) state<=DONE;
    else if(can_start) begin target<=next_count; state<=ISSUE; end
   end
   ISSUE: begin
    if(App_rd_en) begin
     issued<=issued+1'b1;
     address<=address+1'b1;
     if(issued+1'b1==target) state<=DRAIN;
    end
    if(Sdr_rd_en) returned<=returned+1'b1;
   end
   DRAIN: begin
    if(Sdr_rd_en) returned<=returned+1'b1;
    if(returned==target) begin
     remaining<=remaining-target; state<=CHECK;
    end
   end
   DONE: state<=IDLE;
   default: begin state<=IDLE; read_req_ack<=0; fifo_aclr<=1; end
  endcase
 end
end
endmodule
