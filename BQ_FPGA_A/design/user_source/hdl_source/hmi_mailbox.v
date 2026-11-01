// One outstanding command. Source payload is held until a returned toggle;
// destination response is held until the next request. Both resets are from
// the control reset, never the independently restartable media reset.
module hmi_mailbox(
 input source_clk,source_rst,dest_clk,dest_rst,
 input source_valid,input [47:0] source_command,output reg source_done,
 output [39:0] source_response,
 output reg dest_valid,output reg [47:0] dest_command,
 input dest_done,input [39:0] dest_response
);
reg request,ack;reg [47:0] held_command;reg [39:0] held_response;
(* async_reg="true" *) reg [1:0] request_sync,ack_sync;
reg pending,seen;
// Response remains held until the next command. Its consumer samples only
// after the two-stage ACK return; command decode has a destination register.
assign source_response=held_response;
always @(posedge source_clk or posedge source_rst)begin
 if(source_rst)begin request<=0;held_command<=0;ack_sync<=0;pending<=0;source_done<=0;end
 else begin
  ack_sync<={ack_sync[0],ack};source_done<=0;
  if(source_valid && !pending)begin held_command<=source_command;request<=~request;pending<=1;end
  if(pending && ack_sync[1]==request)begin source_done<=1;pending<=0;end
 end
end
always @(posedge dest_clk or posedge dest_rst)begin
 if(dest_rst)begin request_sync<=0;seen<=0;ack<=0;held_response<=0;dest_valid<=0;dest_command<=0;end
 else begin
  request_sync<={request_sync[0],request};dest_valid<=0;
  if(request_sync[1]!=seen)begin seen<=request_sync[1];dest_command<=held_command;dest_valid<=1;end
  if(dest_done)begin held_response<=dest_response;ack<=seen;end
 end
end
endmodule
