// controller B -> player A transactional command mailbox over BQG3.
// Host snapshot: valid, marker=5, cookie(session16+sequence12), command48,
// reserved32, contract CB74. Result68: valid, code7, cookie28, value32.
// Media60 is independent and must never wait for command completion.
module bq_control_host #(parameter CLK_HZ=50000000, TIMEOUT_MS=350,CANCEL_ENABLE=0)(
 input clk,rst,online,input [15:0] session,input valid,input [47:0] command,input cancel,
 output reg done,output reg [39:0] response,
 output [127:0] request_state,output reg request_commit,
 input [67:0] result_state,input result_update);
 localparam TW=$clog2((CLK_HZ/1000)*TIMEOUT_MS+1);
 reg pending;reg [11:0] seq;reg [27:0] cookie;reg [47:0] held;
 reg [TW-1:0] timer;
 assign request_state={pending,3'd5,cookie,held,32'd0,16'hcb74};
 always @(posedge clk or posedge rst)begin
  if(rst)begin pending<=0;seq<=0;cookie<=0;held<=0;timer<=0;done<=0;response<=0;request_commit<=0;end
  else begin
   done<=0;request_commit<=0;
   if(pending)begin
    if(!online)begin pending<=0;done<=1;response<={8'd8,32'd0};request_commit<=1;end
    else if(result_update && result_state[67] && result_state[59:32]==cookie)begin
     pending<=0;done<=1;response<={(result_state[66:60]==4 || result_state[66:60]==6)?8'd11:{1'b0,result_state[66:60]},result_state[31:0]};request_commit<=1;
    end else if(CANCEL_ENABLE && cancel)begin
     // Only the B background glyph owner may cancel. Never cancel a user
     // operation. A late result is ignored by the next transaction cookie;
     // the glyph producer must restart BEGIN after this response.
     pending<=0;done<=1;response<={8'd10,32'd0};request_commit<=1;
    end else if(timer==(CLK_HZ/1000)*TIMEOUT_MS-1)begin
     pending<=0;done<=1;response<={8'd9,32'd0};request_commit<=1;
    end else timer<=timer+1'b1;
   end else if(valid)begin
    if(!online)begin done<=1;response<={8'd8,32'd0};end
    else begin seq<=seq+1'b1;cookie<={session,seq+12'd1};held<=command;pending<=1;timer<=0;request_commit<=1;end
   end
  end
 end
endmodule

module bq_control_target(input clk,rst,online,input [127:0] request_state,
 output reg command_valid,output reg [47:0] command,input command_done,input [39:0] response,
 output [67:0] result_state,output reg result_commit);
 reg busy,have_cookie,result_valid;reg [27:0] cookie;reg [6:0] code;reg [31:0] value;
 wire format_ok=request_state[127] && request_state[126:124]==5 && request_state[47:16]==0 && request_state[15:0]==16'hcb74;
 assign result_state={result_valid,code,cookie,value};
 always @(posedge clk or posedge rst)begin
  if(rst)begin busy<=0;have_cookie<=0;result_valid<=0;cookie<=0;code<=0;value<=0;command_valid<=0;command<=0;result_commit<=0;end
  else begin
   command_valid<=0;result_commit<=0;
   if(busy)begin
    // Drain a dispatched local action even if the peer goes offline. Never
    // use an old completion as the reply to a newer command.
    if(command_done)begin busy<=0;result_valid<=1;code<=response[39]?7'd11:response[38:32];value<=response[31:0];result_commit<=1;end
   end else if(online && format_ok)begin
    if(!have_cookie || cookie!=request_state[123:96])begin
     have_cookie<=1;cookie<=request_state[123:96];command<=request_state[95:48];command_valid<=1;busy<=1;result_valid<=0;result_commit<=1;
    end else if(command!=request_state[95:48] && code!=6)begin
     code<=6;value<=0;result_valid<=1;result_commit<=1;
    end
   end
  end
 end
endmodule
