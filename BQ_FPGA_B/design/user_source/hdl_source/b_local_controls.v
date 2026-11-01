// independent keys, 20ms debounce and four bounded command slots.
// KEY2/KEY3 navigate gardens (SW1 off), photos (SW1 on).
// KEY4 release cycles map/intro/list; hold 1s returns to the map.
// In list: KEY2 adds selected garden, KEY3 removes last; SW1 KEY2 restores
// default tour, SW1 KEY3 clears. SW2 selects A media controls instead:
// KEY2 next/replay, KEY3 previous/return photos, KEY4 pause;
// hold KEY4 toggles photo/video mode. No UART session required.
module b_local_controls #(parameter CLK_HZ=50000000)(
 input clk,rst,input [2:0] keys_n,input [1:0] switches,
 input [67:0] desired,input [127:0] applied,remote,
 input [2:0] list_count,input ready,
 output valid,output [47:0] command,output reg [15:0] drops
);
 (* ASYNC_REG="TRUE" *) reg [4:0] sync0,sync1;
 reg [4:0] stable;reg [4:0] db[0:4];
 reg [$clog2(CLK_HZ/1000)-1:0] divider;
 wire ms=divider==CLK_HZ/1000-1;
 reg [2:0] press;reg release4,long4;reg [9:0] hold4;
 reg [47:0] queue[0:3];reg [1:0] wr,rd;reg [2:0] count;
 reg push;reg [47:0] intent;integer i;
 wire [3:0] poi=desired[65]?desired[63:60]:(applied[71:68]>=1 && applied[71:68]<=4?applied[71:68]:4'd1);
 wire [3:0] index=desired[59:56];
 assign valid=count!=0;assign command=queue[rd];
 wire pop=valid && ready;
 always @*begin
  push=0;intent=0;
  if(stable[4])begin
   if(long4)begin push=1;intent={8'h20,8'h00,31'd0,!remote[78]};end
   else if(press[0])begin push=1;intent=remote[78]?{8'h20,8'h07,32'd0}:{8'h20,8'h01,32'd0};end
   else if(press[1])begin push=1;intent=remote[78]?{8'h20,8'h00,32'd0}:{8'h20,8'h02,32'd0};end
   else if(release4)begin push=1;intent={8'h20,8'h04,31'd0,remote[79]};end
  end else if(long4)begin push=1;intent={8'h10,8'h30,32'd0};end
  else if(release4)begin push=1;intent={8'h10,8'h30,30'd0,(desired[67:66]==2?2'd0:desired[67:66]+2'd1)};end
  else if(desired[67:66]==2)begin
   if(press[0])begin push=1;intent=stable[3]?{8'h10,8'h39,32'd0}:{8'h10,8'h34,28'd0,poi};end
   else if(press[1] && (stable[3] || list_count!=0))begin push=1;intent=stable[3]?{8'h10,8'h38,32'd0}:{8'h10,8'h35,29'd0,list_count-3'd1};end
  end else if(press[0] || press[1])begin
   push=1;
   if(stable[3])intent={8'h10,8'h33,28'd0,(press[0]?(index==2?4'd0:index+4'd1):(index==0?4'd2:index-4'd1))};
   else intent={8'h10,8'h32,28'd0,(press[0]?(poi==4?4'd1:poi+4'd1):(poi==1?4'd4:poi-4'd1))};
  end
 end
 always @(posedge clk or posedge rst)begin
  if(rst)begin
   sync0<=5'b00111;sync1<=5'b00111;stable<=5'b00111;divider<=0;press<=0;release4<=0;long4<=0;hold4<=0;
   wr<=0;rd<=0;count<=0;drops<=0;for(i=0;i<5;i=i+1)db[i]<=0;
  end else begin
   sync0<={switches,keys_n};sync1<=sync0;press<=0;release4<=0;long4<=0;
   if(ms)begin
    divider<=0;
    for(i=0;i<5;i=i+1)begin
     if(sync1[i]==stable[i])db[i]<=0;
     else if(db[i]==19)begin
      db[i]<=0;stable[i]<=sync1[i];
      if(i<2 && !sync1[i])press[i]<=1;
      if(i==2 && sync1[i] && hold4<1000)release4<=1;
     end else db[i]<=db[i]+1'b1;
    end
    if(stable[2])hold4<=0;
    else if(hold4<1000)begin hold4<=hold4+1'b1;if(hold4==999)long4<=1;end
   end else divider<=divider+1'b1;
   if(push && (count<4 || pop))begin queue[wr]<=intent;wr<=wr+1'b1;end
   else if(push && drops!=65535)drops<=drops+1'b1;
   if(pop)rd<=rd+1'b1;
   case({push && (count<4 || pop),pop})2'b10:count<=count+1'b1;2'b01:count<=count-1'b1;default:begin end endcase
  end
 end
endmodule

// Holds both source payloads across service wait; exactly one completion is
// returned to the requesting source. A missing screen cannot gate local keys.
module b_command_arbiter(input clk,rst,
 input touch_valid,input [47:0] touch_command,output touch_done,output [39:0] touch_response,
 input local_valid,input [47:0] local_command,output local_ready,
 output reg service_valid,output [47:0] service_command,input service_done,input [39:0] service_response);
 reg touch_pending,busy,from_touch;reg [47:0] held_local;
 // hmi_link retains last_op/object/value until this transaction completes.
 // Keep only a pending bit instead of duplicating its 48-bit payload twice.
 assign service_command=from_touch?touch_command:held_local;
 assign local_ready=!busy && !touch_pending && !touch_valid;
 assign touch_done=busy && from_touch && service_done;
 assign touch_response=service_response;
 always @(posedge clk or posedge rst)begin
  if(rst)begin touch_pending<=0;busy<=0;from_touch<=0;held_local<=0;service_valid<=0;end
  else begin
   service_valid<=0;
   if(touch_valid)touch_pending<=1;
   if(busy)begin if(service_done)busy<=0;end
   else if(touch_pending)begin touch_pending<=0;busy<=1;from_touch<=1;service_valid<=1;end
   else if(local_valid && local_ready)begin held_local<=local_command;busy<=1;from_touch<=0;service_valid<=1;end
  end
 end
endmodule
