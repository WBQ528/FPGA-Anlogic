// pixel-clock-domain UART service for the remote B renderer.
// The parent transports desired_control and supplies a coherent applied_state.
// A transport ACK is not an application ACK: SET waits for B's generation.
module hmi_b_service #(parameter integer CLK_HZ=74166667)(
 input clk,rst,valid,
 input [47:0] command,
 output reg done,
 output reg [39:0] response,
 input [127:0] applied_state,
 input phy_link,peer_online,stale,
 output reg [67:0] desired_control
);
localparam integer WAIT_CYCLES=(CLK_HZ<5)?1:CLK_HZ/5;
localparam integer TIMER_BITS=(WAIT_CYCLES<2)?1:$clog2(WAIT_CYCLES);
localparam [67:0] DEFAULT_CONTROL={4'b0000,8'd0,8'd0,8'd100,4'd0,4'd0,16'd0,16'hcb70};
wire [7:0] op=command[47:40],obj=command[39:32];
wire [31:0] value=command[31:0];
wire available=phy_link && peer_online && !stale;
reg waiting,armed,decoding;
reg range_q,readable_q,writable_q,get_q,set_q,zero_q,status_q;
reg [3:0] saved_obj;
reg [TIMER_BITS-1:0] timer;
reg range_ok;
wire writable=(obj[7:4]==4'h3 && obj[3:0]<=8);
wire readable=writable || obj==8'h3e || obj==8'h3f;
wire [31:0] status_word={applied_state[31:16],4'd0,applied_state[35:32],3'd0,
 (applied_state[35:32]!=0),(desired_control[31:16]!=applied_state[31:16]),
 applied_state[77],(peer_online && !stale),phy_link};

function [31:0] actual_value;
 input [7:0] id;
 input [127:0] s;
 begin
  case(id)
   8'h30:actual_value={31'd0,s[67]};
   8'h31:actual_value={31'd0,s[66]};
   8'h32:actual_value={28'd0,s[39:36]};
   8'h33:actual_value={{24{s[63]}},s[63:56]};
   8'h34:actual_value={{24{s[55]}},s[55:48]};
   8'h35:actual_value={24'd0,s[47:40]};
   8'h36:actual_value=0;
   8'h37:actual_value={31'd0,s[65]};
   8'h38:actual_value={31'd0,s[64]};
   8'h3f:actual_value=s[111:80];
   default:actual_value=0;
  endcase
 end
endfunction
wire [7:0] lookup_obj=waiting?{4'h3,saved_obj}:obj;
wire [31:0] lookup_value=actual_value(lookup_obj,applied_state);

always @* begin
 range_ok=0;
 case(obj)
  8'h30,8'h31,8'h32,8'h37,8'h38:range_ok=(value[31:1]==0);
  8'h33:range_ok=(value[31:8]=={24{value[7]}} && $signed(value[7:0])>=-8'sd40 && $signed(value[7:0])<=8'sd40);
  8'h34:range_ok=(value[31:8]=={24{value[7]}} && $signed(value[7:0])>=-8'sd24 && $signed(value[7:0])<=8'sd24);
  8'h35:range_ok=(value[31:8]==0 && value[7:0]>=8'd75 && value[7:0]<=8'd150);
  8'h36:range_ok=(value==1);
  default:range_ok=0;
 endcase
end

// The UART mailbox holds command until done. Decode before committing
// a response; this extra pixel clock is negligible relative to UART framing.
always @(posedge clk)begin
 range_q<=range_ok;readable_q<=readable;writable_q<=writable;
 get_q<=op==8'h01;set_q<=op==8'h10;zero_q<=value==0;status_q<=obj==8'h3e;
end
always @(posedge clk or posedge rst) begin
 if(rst) begin
  desired_control<=DEFAULT_CONTROL;
  done<=0;response<=0;waiting<=0;armed<=1;decoding<=0;saved_obj<=0;timer<=0;
 end else begin
  done<=0;
  if(!valid) armed<=1;
  if(waiting) begin
   if(!available) begin
    response<={8'd8,32'd0};done<=1;waiting<=0;
   end else if(applied_state[31:16]==desired_control[31:16]) begin
    response<={(applied_state[35:32]==0 ? 8'd0 : 8'd8),lookup_value};
    done<=1;waiting<=0;
   end else if(timer==WAIT_CYCLES-1) begin
    response<={8'd1,lookup_value};
    done<=1;waiting<=0;
   end else timer<=timer+1'b1;
  end else if(valid && armed) begin
   armed<=0;decoding<=1;
  end else if(decoding) begin
   decoding<=0;done<=1;response<=0;
   if(get_q) begin
    if(!readable_q) response<={8'd3,32'd0};
    else if(!zero_q) response<={8'd2,32'd0};
    else if(status_q) response<={8'd0,status_word};
    else if(!available) response<={8'd8,32'd0};
    else response<={8'd0,lookup_value};
   end else if(set_q) begin
    if(!writable_q) response<={8'd3,32'd0};
    else if(!range_q) response<={8'd2,lookup_value};
    else if(!available) response<={8'd8,32'd0};
    else begin
     desired_control[31:16]<=desired_control[31:16]+1'b1;
     desired_control[35:32]<=0;
     desired_control[15:0]<=16'hcb70;
     case(obj)
      8'h30:begin desired_control[67]<=value[0];desired_control[66]<=value[0];end
      8'h31:desired_control[66]<=value[0];
      8'h32:desired_control[39:36]<=value[3:0];
      8'h33:desired_control[63:56]<=value[7:0];
      8'h34:desired_control[55:48]<=value[7:0];
      8'h35:desired_control[47:40]<=value[7:0];
      8'h36:begin
       desired_control[63:56]<=0;desired_control[55:48]<=0;
       desired_control[47:40]<=100;desired_control[65:64]<=0;
      end
      8'h37:desired_control[65]<=value[0];
      8'h38:desired_control[64]<=value[0];
      default:begin end
     endcase
     saved_obj<=obj[3:0];timer<=0;waiting<=1;done<=0;
    end
   end else response<={8'd3,32'd0};
  end
 end
end
endmodule
