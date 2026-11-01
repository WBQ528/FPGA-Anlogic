// B controls. Page confirmation follows the actual display revision.
// Itinerary edits are processed locally and never wait for remote A or QR work.
module hmi_b_service #(parameter integer CLK_HZ=50000000)(
 input clk,rst,valid,input [47:0] command,
 output reg done,output reg [39:0] response,input [127:0] applied_state,
 input phy_link,peer_online,stale,output reg [67:0] desired_control,
 output reg list_edit,output reg [2:0] list_op,output reg [3:0] list_value,
 input list_done,input [7:0] list_code,input [11:0] list_order,input [2:0] list_count,
 input list_ready,list_busy,input [31:0] list_revision
);
localparam WAIT_CYCLES=CLK_HZ/50,TIMER_BITS=$clog2(WAIT_CYCLES);
reg [2:0] state;reg armed;reg [TIMER_BITS-1:0] timer;reg [7:0] saved_obj;
wire [7:0] op=command[47:40],obj=command[39:32];wire [31:0] value=command[31:0];
wire available=phy_link && peer_online && !stale;
wire [31:0] list_status={15'd0,list_busy,list_ready,list_count,list_order};
function [31:0] actual;input [7:0] id;input [127:0] s;begin case(id)
 8'h30:actual={30'd0,s[67:66]};8'h31:actual={31'd0,s[65]};
 8'h32:actual={28'd0,s[63:60]};8'h33:actual={28'd0,s[59:56]};
 8'h3f:actual=s[111:80];default:actual=0;
endcase end endfunction
wire [31:0] actual_value=actual(saved_obj,applied_state);
always @(posedge clk or posedge rst)begin
 if(rst)begin
  desired_control<=68'h0100000000000cb74; // page map, follow, default garden 1
  state<=0;armed<=1;done<=0;response<=0;timer<=0;saved_obj<=0;list_edit<=0;list_op<=0;list_value<=0;
 end else begin
  done<=0;list_edit<=0;if(!valid)armed<=1;
  case(state)
   0:if(valid && armed)begin armed<=0;state<=1;end
   1:begin
    done<=1;response<=0;state<=0;
    if(op==1)begin
     if(value!=0)response<={8'd2,32'd0};
     else case(obj)
      8'h30,8'h31,8'h32,8'h33,8'h3f:response<={8'd0,actual(obj,applied_state)};
      8'h3c:response<={8'd0,20'd0,applied_state[67:56]};
      8'h3a:response<={8'd0,list_status};8'h3b:response<={8'd0,list_revision};
      8'h3e:response<={8'd0,applied_state[31:16],4'd0,applied_state[35:32],3'd0,
       (applied_state[35:32]!=0),(desired_control[31:16]!=applied_state[31:16]),applied_state[77],(peer_online && !stale),phy_link};
      default:response<={8'd3,32'd0};
     endcase
    end else if(op==8'h10)begin
     if(obj>=8'h34 && obj<=8'h39)begin
      if(value[31:4]!=0 || (obj>=8'h38 && value!=0))response<={8'd2,list_status};
      else begin list_edit<=1;list_op<=obj-8'h33;list_value<=value[3:0];state<=3;done<=0;end
     end else if((obj==8'h30 && value<=2) || (obj==8'h31 && value<=1) ||
       (obj==8'h32 && value>=1 && value<=4) || (obj==8'h33 && value<=2))begin
      if(!available)response<={8'd8,32'd0};
      else begin
       desired_control[31:16]<=desired_control[31:16]+1'b1;desired_control[35:32]<=0;
       case(obj)
        8'h30:begin
         desired_control[67:66]<=value[1:0];
         if(value==0)desired_control[65]<=0;
         if(value==1)begin desired_control[65]<=1;desired_control[63:60]<=applied_state[71:68]>=1 && applied_state[71:68]<=4 ? applied_state[71:68]:4'd1;desired_control[59:56]<=0;end
        end
        8'h31:begin
         desired_control[65]<=value[0];if(!value[0])desired_control[67:66]<=0;
         else begin desired_control[63:60]<=applied_state[71:68]>=1 && applied_state[71:68]<=4 ? applied_state[71:68]:4'd1;desired_control[59:56]<=0;end
        end
        8'h32:begin desired_control[63:60]<=value[3:0];desired_control[59:56]<=0;desired_control[65]<=1;desired_control[67:66]<=1;end
        8'h33:begin desired_control[59:56]<=value[3:0];desired_control[65]<=1;desired_control[67:66]<=1;end
       endcase
       saved_obj<=obj;timer<=0;state<=2;done<=0;
      end
     end else response<={(obj<=8'h33  ? 8'd2:8'd3),32'd0};
    end else response<={8'd3,32'd0};
   end
   2:if(applied_state[35:32]!=0)begin response<={8'd8,actual_value};done<=1;state<=0;end
     else if(applied_state[31:16]==desired_control[31:16])begin response<={applied_state[35:32]==0 ? 8'd0:8'd8,actual_value};done<=1;state<=0;end
     else if(timer==WAIT_CYCLES-1)begin response<={8'd1,actual_value};done<=1;state<=0;end
     else timer<=timer+1'b1;
   3:if(list_done)begin response<={list_code,list_status};done<=1;state<=0;end
   default:state<=0;
  endcase
 end
end
endmodule
