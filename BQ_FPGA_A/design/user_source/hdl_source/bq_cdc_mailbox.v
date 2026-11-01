// One stable source bundle; ACK is returned only after destination consumption.
// Common asynchronous assertion and per-domain synchronous reset release required.
// Data crosses combinationally but is stable for at least three dst clocks before valid.
module bq_cdc_mailbox #(parameter WIDTH=128,parameter SOURCE_HOLDS=0,parameter REGISTER_OUTPUT=1)(
 input src_clk,input src_rst_n,input [WIDTH-1:0] src_data,input src_valid,
 output src_ready,input dst_clk,input dst_rst_n,
 output [WIDTH-1:0] dst_data,output dst_valid,input dst_ready);
 reg request,ack;
 (* ASYNC_REG="TRUE" *) reg [2:0] ack_sync,req_sync;
 wire [WIDTH-1:0] crossing_data;
 generate if(SOURCE_HOLDS)begin: external_bundle
  // Producer must keep src_valid and src_data stable until src_ready.
  // Request launches when valid is observed; ready acknowledges consumption.
  reg busy;
  assign crossing_data=src_data;
  assign src_ready=busy&&(request==ack_sync[2]);
  always @(posedge src_clk or negedge src_rst_n)
  if(!src_rst_n)begin request<=0;ack_sync<=0;busy<=0;end
  else begin
   ack_sync<={ack_sync[1:0],ack};
   if(src_valid&&!busy)begin request<=~request;busy<=1;end
   if(src_ready)busy<=0;
  end
 end else begin: internal_bundle
  reg [WIDTH-1:0] hold_data;
  assign crossing_data=hold_data;
  assign src_ready=(request==ack_sync[2]);
  always @(posedge src_clk or negedge src_rst_n)
  if(!src_rst_n)begin request<=0;hold_data<=0;ack_sync<=0;end
  else begin
   ack_sync<={ack_sync[1:0],ack};
   if(src_valid&&src_ready)begin hold_data<=src_data;request<=~request;end
  end
 end endgenerate
 always @(posedge dst_clk or negedge dst_rst_n)
 if(!dst_rst_n)req_sync<=0;
 else req_sync<={req_sync[1:0],request};
 generate if(REGISTER_OUTPUT)begin: registered_output
  reg [WIDTH-1:0] value;
  reg valid;
  assign dst_data=value;
  assign dst_valid=valid;
  always @(posedge dst_clk or negedge dst_rst_n)
  if(!dst_rst_n)begin ack<=0;value<=0;valid<=0;end
  else begin
   if(valid&&dst_ready)valid<=0;
   if(req_sync[2]!=ack&&(!valid||dst_ready))begin
    value<=crossing_data;valid<=1;ack<=req_sync[2];
   end
  end
 end else begin: unregistered_output
  // The consumer may use data only while valid, and ready marks FINAL consumption.
  assign dst_data=crossing_data;
  assign dst_valid=(req_sync[2]!=ack);
  always @(posedge dst_clk or negedge dst_rst_n)
  if(!dst_rst_n)ack<=0;
  else if(dst_valid&&dst_ready)ack<=req_sync[2];
 end endgenerate
endmodule

module bq_reset_sync(input clk,input arst_n,output rst_n);
 (* ASYNC_REG="TRUE" *) reg [2:0] release_sync;
 always @(posedge clk or negedge arst_n)
 if(!arst_n)release_sync<=0;else release_sync<={release_sync[1:0],1'b1};
 assign rst_n=release_sync[2];
endmodule
