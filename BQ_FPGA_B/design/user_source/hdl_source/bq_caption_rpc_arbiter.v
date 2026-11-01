// Exactly one background glyph word in flight. User commands have priority at
// every word boundary. A lost glyph response may not hold controls for the
// ordinary RPC timeout: cancel only that background word after PREEMPT_CYCLES.
// The producer receives code 10 and restarts the incomplete caption at BEGIN.
module bq_caption_rpc_arbiter #(parameter integer PREEMPT_CYCLES=100000)(
 input clk,rst,
 input user_valid,input [47:0] user_command,output reg user_done,output reg [39:0] user_response,
 input glyph_valid,input [47:0] glyph_command,output reg glyph_ready,glyph_done,output reg [39:0] glyph_response,
 output reg host_valid,output reg [47:0] host_command,input host_done,input [39:0] host_response,
 output host_cancel
);
 localparam integer TW=$clog2(PREEMPT_CYCLES+1);
 reg [1:0] owner;reg user_pending;reg [47:0] user_held;reg [TW-1:0] age;
 assign host_cancel=owner==2 && user_pending && age==PREEMPT_CYCLES-1;
 always @(posedge clk or posedge rst)begin
  if(rst)begin
   owner<=0;user_pending<=0;user_held<=0;age<=0;host_valid<=0;host_command<=0;
   user_done<=0;user_response<=0;glyph_ready<=0;glyph_done<=0;glyph_response<=0;
  end else begin
   host_valid<=0;user_done<=0;glyph_ready<=0;glyph_done<=0;
   // The foreground service contract allows only one pending user request;
   // its caller keeps later discrete intents in the existing bounded queue.
   if(user_valid && !user_pending)begin user_pending<=1;user_held<=user_command;end
   if(owner==2 && age<PREEMPT_CYCLES-1)age<=age+1'b1;
   if(owner!=0 && host_done)begin
    owner<=0;age<=0;
    if(owner==1)begin user_done<=1;user_response<=host_response;end
    else begin glyph_done<=1;glyph_response<=host_response;end
   end else if(owner==0)begin
    age<=0;
    if(user_pending)begin
     user_pending<=0;owner<=1;host_valid<=1;host_command<=user_held;
    end else if(!user_valid && glyph_valid)begin
     owner<=2;host_valid<=1;host_command<=glyph_command;glyph_ready<=1;
    end
   end
  end
 end
endmodule
