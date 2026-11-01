// R6 pixel-domain command service. Absolute parameter writes share the local
// controls. Two frame boundaries elapse before parameter confirmation; local
// changes during that interval return SUPERSEDED and the current value.
module hmi_service #(parameter WATCHDOG_BITS=24)(
 input clk,rst,media_ready,frame_tick,
 input valid,input [47:0] command,output reg done,output reg [39:0] response,
 output reg ui_valid,output reg [3:0] ui_field,output reg [7:0] ui_value,
 output reg sd_valid,output [47:0] sd_command,input sd_done,input [39:0] sd_response,
 output reg restart_toggle,output reg [1:0] restart_mode,output reg [2:0] restart_chapter,
 input [2:0] current_chapter,
 input movie,tone,display_valid,photo_busy,photo_paused,photo_auto,
 input [1:0] period,input [4:0] photo_count,input [3:0] photo_id,
 input [10:0] native_w,native_h,input paused,muted,ended,
 input [15:0] shown_frame,total_frames,stalls,underruns,
 input [3:0] media_error,native_error,input [15:0] native_retries,
 input signed [3:0] brightness,input [2:0] contrast,zoom,
 input [1:0] fit,effect,input [3:0] volume,options,
 input photo_muted,caption_enabled,input [1:0] caption_motion,input [5:0] caption_speed
);
wire [7:0] op=command[47:40],obj=command[39:32];wire [31:0] value=command[31:0];
// The source mailbox holds command through completion. The SD mailbox takes
// its own copy on sd_valid; no additional payload register is needed here.
assign sd_command=command;
reg [2:0] state;reg [3:0] saved_field;reg [7:0] saved_value;reg first_frame;
reg [WATCHDOG_BITS-1:0] watchdog;
function [7:0] parameter_byte;input [3:0] field;input [31:0] p;
 begin case(field)
  0:parameter_byte={{4{p[3]}},p[3:0]};1:parameter_byte={5'd0,p[6:4]};
  2:parameter_byte={6'd0,p[8:7]};3:parameter_byte={5'd0,p[11:9]};4:parameter_byte={6'd0,p[13:12]};
  5:parameter_byte={4'd0,p[17:14]};6:parameter_byte={4'd0,p[21:18]};7:parameter_byte={7'd0,p[22]};
  8:parameter_byte={7'd0,p[23]};9:parameter_byte={6'd0,p[25:24]};10:parameter_byte={2'd0,p[31:26]};
  default:parameter_byte=0;
 endcase end
endfunction
wire [31:0] parameter_bits={caption_speed,caption_motion,caption_enabled,photo_muted,options,volume,effect,zoom,fit,contrast,brightness};
wire [7:0] read_byte=parameter_byte(obj[3:0],parameter_bits);
wire [7:0] actual_byte=parameter_byte(saved_field,parameter_bits);
wire [31:0] read_value={{24{read_byte[7]}},read_byte};
wire [31:0] actual_value={{24{actual_byte[7]}},actual_byte};
reg op_get_q,op_set_q,op_media_q,value_zero_q,query_parameter_q,range_ok_q;
// The destination mailbox holds command until done. State 5 permits one
// decode clock before applying it; UART and wire protocol remain unchanged.
always @(posedge clk)begin
 op_get_q<=op==1;op_set_q<=op==8'h10;op_media_q<=op==8'h20;
 value_zero_q<=value==0;query_parameter_q<=obj>=8'h10 && obj<=8'h1a;
 range_ok_q<=range_ok;
end
reg range_ok;
always @*begin
 range_ok=0;
 case(obj)
  0:range_ok=(value[31:3]==0 && value[2:0]<=4) || (&value[31:2]);
  1,3:range_ok=value[31:3]==0 && value[2:0]<=4;
  2,9:range_ok=value[31:2]==0 && value[1:0]!=3;
  4:range_ok=value[31:2]==0;
  5:range_ok=value[31:4]==0 && value[3:0]<=10;
  6:range_ok=value[31:4]==0;7,8:range_ok=value[31:1]==0;
  10:range_ok=value[31:6]==0 && value[5:0]!=0 && value[5:0]<=32;
  default:range_ok=0;
 endcase
end
always @(posedge clk or posedge rst)begin
 if(rst)begin
  done<=0;response<=0;ui_valid<=0;ui_field<=0;ui_value<=0;sd_valid<=0;
  restart_toggle<=0;restart_mode<=0;restart_chapter<=0;state<=0;saved_field<=0;saved_value<=0;first_frame<=0;watchdog<=0;
 end else begin
  done<=0;ui_valid<=0;sd_valid<=0;
  if(state!=0 && state!=4)watchdog<=watchdog+1'b1;else watchdog<=0;
  case(state)
   0:if(valid)state<=5;
   5:begin
    response<=0;done<=1;state<=0;
    if(op_get_q)begin
     if(!value_zero_q)response<={8'd2,32'd0};
     else if(query_parameter_q)response<={8'd0,read_value};
     else if(obj==7 || obj==12 || (obj>=8'h80 && obj<=8'h8f))begin sd_valid<=1;done<=0;state<=2;end
     else case(obj)
      0:response<={8'd0,32'h00020006}; // frame version 6, incompatible business contract 2
      1:response<={8'd0,32'h000007ff}; // documented capabilities, no new media algorithms
      2:response<={8'd0,20'd0,media_error,photo_busy,display_valid,ended,muted,paused,photo_auto,tone,movie};
      3:response<={8'd0,19'd0,photo_paused,photo_auto,period,photo_count,photo_id};
      4:response<={8'd0,5'd0,native_w,5'd0,native_h};
      5:response<={8'd0,total_frames,shown_frame};
      6:response<={8'd0,stalls,underruns};
      7:response<={8'd0,16'd0,native_retries};
      8:response<={8'd0,16'd1280,16'd960};
      9:response<={8'd0,16'd1280,16'd720};
      10:response<={8'd0,16'd30,16'd48000};
      11:response<={8'd0,31'd0,media_ready};
      13:response<={8'd0,29'd0,current_chapter};
      // One coherent read replaces up to eleven individual parameter GETs.
      8'h2c:response<={8'd0,parameter_bits};
      8'h2d:response<={8'd0,7'd0,photo_paused,photo_auto,period,photo_count,photo_id,
        media_error,photo_busy,display_valid,ended,muted,paused,photo_auto,tone,movie};
      default:response<={8'd3,32'd0};
     endcase
    end else if(!media_ready)response<={8'd8,32'd0};
    else if(op_set_q)begin
     if(obj>10)response<={8'd3,32'd0};
     else if(!range_ok_q)response<={8'd2,read_value};
     else begin
      ui_valid<=1;ui_field<=obj[3:0];ui_value<=value[7:0];saved_field<=obj[3:0];saved_value<=value[7:0];
      first_frame<=0;state<=1;done<=0;
     end
    end else if(op_media_q)begin
     case(obj)
      0:if(value>1)response<={8'd2,32'd0};else begin restart_mode<=value[1:0];restart_chapter<=0;restart_toggle<=~restart_toggle;response<={8'd1,30'd0,value[1:0]};end
      1,2,3,4,5,6,8:begin
       if((obj==1 || obj==2 || obj==5) && (movie || value!=0))response<={8'd3,32'd0};
       else if(obj==3 && (movie || value[31:4]!=0))response<={8'd2,32'd0};
       else if(obj==4 && (value[31:1]!=0 || (movie && ended && value!=0)))response<={8'd8,32'd0};
       else if(obj==6 && (movie || value>1))response<={8'd2,32'd0};
       else if(obj==8 && value[31:1]!=0)response<={8'd2,32'd0};
       else if(obj==8 && !movie)begin
        ui_valid<=1;ui_field<=7;ui_value<=value[7:0];saved_field<=7;saved_value<=value[7:0];first_frame<=0;state<=1;done<=0;
       end else begin sd_valid<=1;state<=2;done<=0;end
      end
      7,10:if(!value_zero_q)response<={8'd2,32'd0};else begin restart_mode<=movie?2'd1:2'd0;restart_chapter<=0;restart_toggle<=~restart_toggle;response<={8'd1,32'd0};end
      11:if(value<1 || value>4)response<={8'd2,32'd0};else begin
       restart_mode<=1;restart_chapter<=value[2:0];restart_toggle<=~restart_toggle;response<={8'd1,value};
      end
      9:if(!value_zero_q)response<={8'd2,32'd0};else begin
       ui_valid<=1;ui_field<=15;ui_value<=0;saved_field<=15;saved_value<=0;first_frame<=0;state<=1;done<=0;
      end
      default:response<={8'd3,32'd0};
     endcase
    end else response<={8'd3,32'd0};
   end
   1:if(frame_tick)begin if(first_frame)state<=3;else first_frame<=1;end
   2:if(sd_done)begin response<=sd_response;done<=1;state<=0;end
   3:begin
    response<={(actual_byte==saved_value?8'd0:8'd10),actual_value};
    done<=1;state<=0;
   end
   4:begin
    // Drain the timed-out mailbox before reusing it. A late response cannot
    // complete a newer command. Queries can be retried once the drain ends.
    if(valid)begin response<={8'd8,32'd0};done<=1;end
    if(sd_done)state<=0;
   end
   default:state<=0;
  endcase
  // 2^24 pixel clocks (~226 ms) bounds any service wait. Media reset does not
  // erase the request. Only the control reset resets the UART session.
  if(state!=0 && state!=4 && &watchdog && !(state==2 && sd_done))begin response<={8'd9,32'd0};done<=1;state<=state==2?3'd4:3'd0;end
 end
end
endmodule
