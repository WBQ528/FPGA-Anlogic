// B-owned text service. Copy/validation takes microseconds and ACKs the
// accepted generation; font IO/network/rendering proceed independently.
// GET 65 reports actual render generations, never treats acceptance as display.
module bq_caption_service(
 input clk,rst,valid,input [47:0] command,
 output reg done,output reg [39:0] response,
 output [5:0] text_address,input [7:0] text_data,
 output reg accepted,output updating,output reg [15:0] desired_epoch,
 output reg [5:0] char_count,input [4:0] char_address,output reg [15:0] character,
 input [15:0] local_epoch,remote_epoch,input remote_online,input [7:0] render_error,
 input [5:0] local_count,input [8:0] local_settings,remote_settings,input remote_settings_known,
 output reg enabled,output reg [1:0] motion,output reg [5:0] speed
);
 reg [15:0] characters[0:31];
 reg [2:0] state;reg parse_start;reg [6:0] byte_length;reg [4:0] read_character;
 wire parse_busy,parse_done;wire [7:0] parse_error;wire [5:0] parsed_count;wire [15:0] parsed_character;
 bq_caption_text parser(.clk(clk),.rst(rst),.start(parse_start),.byte_length(byte_length),
  .text_address(text_address),.text_data(text_data),.busy(parse_busy),.done(parse_done),.code(parse_error),
  .char_count(parsed_count),.char_address(read_character),.char_code(parsed_character));
 assign updating=state!=0;
 always @(posedge clk)begin
  character<=characters[char_address];
  if(state==3)characters[read_character]<=parsed_character;
 end
 wire [15:0] next_epoch=desired_epoch==16'hffff ? 16'd1 : desired_epoch+16'd1;
 wire local_pending=local_epoch!=desired_epoch;
 wire remote_pending=remote_epoch!=desired_epoch;
 wire [8:0] desired_settings={speed,motion,enabled};
 wire local_config_pending=local_settings!=desired_settings;
 wire remote_config_pending=!remote_settings_known || remote_settings!=desired_settings;
 wire [31:0] status_word={desired_epoch,render_error,2'd0,remote_config_pending,local_config_pending,remote_pending,remote_online,local_pending,desired_epoch!=0};
 // Readback describes the frame-acknowledged B display, not the last SET ACK.
 wire [31:0] settings_word={17'd0,local_count,local_settings};
 always @(posedge clk or posedge rst)begin
  if(rst)begin
   state<=0;done<=0;response<=0;parse_start<=0;byte_length<=0;read_character<=0;
   accepted<=0;desired_epoch<=0;char_count<=0;enabled<=1;motion<=1;speed<=4;
  end else begin
   done<=0;accepted<=0;parse_start<=0;
   case(state)
    0:if(valid)begin
     response<=0;done<=1;
     if(command[47:40]==8'h40 && command[39:32]==8'h40)begin
      if(command[31:24]>64 || command[23:16]!=0)response<={8'd2,32'd0};
      else begin byte_length<=command[30:24];parse_start<=1;state<=1;done<=0;end
     end else if(command[47:40]==1 && command[31:0]==0)begin
      case(command[39:32])
       8'h41:response<={8'd0,status_word};
       8'h42:response<={8'd0,settings_word};
       default:response<={8'd3,32'd0};
      endcase
     end else if(command[47:40]==8'h10)begin
      case(command[39:32])
       8'h43:if(command[31:0]<=1)begin enabled<=command[0];response<={8'd1,command[31:0]};end else response<={8'd2,32'd0};
       8'h44:if(command[31:0]<=2)begin motion<=command[1:0];response<={8'd1,command[31:0]};end else response<={8'd2,32'd0};
       8'h45:if(command[31:0]>=1 && command[31:0]<=32)begin speed<=command[5:0];response<={8'd1,command[31:0]};end else response<={8'd2,32'd0};
       default:response<={8'd3,32'd0};
      endcase
     end else response<={8'd2,32'd0};
    end
    1:if(parse_done)begin
     if(parse_error!=0)begin done<=1;response<={parse_error,32'd0};state<=0;end
     else if(parsed_count==0)state<=4;
     else begin read_character<=0;state<=2;end
    end
    2:state<=3; // Registered parser RAM read latency.
    3:if({1'b0,read_character}+6'd1==parsed_count)state<=4;
      else begin read_character<=read_character+1'b1;state<=2;end
    4:begin
     char_count<=parsed_count;desired_epoch<=next_epoch;accepted<=1;
     done<=1;response<={8'd1,16'd0,next_epoch};state<=0;
    end
    default:state<=0;
   endcase
  end
 end
endmodule
