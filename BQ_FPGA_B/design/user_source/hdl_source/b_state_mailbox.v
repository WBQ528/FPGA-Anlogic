// Latest-state CDC mailbox. Whole payload remains immutable while in flight.
// Intermediate updates may coalesce; a received state is never torn.
module b_state_mailbox #(parameter WIDTH=128)(
 input source_clk,source_rst,input update,input [WIDTH-1:0] data,
 input dest_clk,dest_rst,output reg valid,output reg [WIDTH-1:0] received
);
reg [WIDTH-1:0] latest,held; reg dirty,req,ack;
(* async_reg="true" *) reg [1:0] req_sync,ack_sync;
reg seen;
always @(posedge source_clk or posedge source_rst)begin
 if(source_rst)begin latest<=0;held<=0;dirty<=0;req<=0;ack_sync<=0;end
 else begin
  ack_sync<={ack_sync[0],ack};
  if(dirty && ack_sync[1]==req)begin held<=latest;req<=~req;dirty<=0;end
  if(update)begin latest<=data;dirty<=1;end
 end
end
always @(posedge dest_clk or posedge dest_rst)begin
 if(dest_rst)begin req_sync<=0;seen<=0;ack<=0;received<=0;valid<=0;end
 else begin
  req_sync<={req_sync[0],req};valid<=0;
  if(req_sync[1]!=seen)begin received<=held;valid<=1;seen<=req_sync[1];ack<=req_sync[1];end
 end
end
endmodule
