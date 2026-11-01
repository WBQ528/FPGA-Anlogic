// SD-domain adapter for the adopted 9BCE screen contract.
// Kept separate from transport and media engines: ACK acceptance is not display completion.
// A media reset aborts pending work; control reset owns the UART session.
module hmi_media_adapter(
 input clk,rst,media_reset,movie,valid,input [47:0] command,
 output reg done,output reg [39:0] response,
 output reg photo_valid,movie_valid,output reg [2:0] photo_op,
 input photo_done,input [7:0] photo_code,input [3:0] photo_target,
 input [4:0] photo_count,input [3:0] native_error,input [15:0] native_retries,
 input native_high_speed,input [2:0] native_speed_status,
 output reg catalog_height,input [15:0] catalog_data,input catalog_ready
);
reg [2:0] state;reg [1:0] catalog_delay;reg [15:0] catalog_width;
wire [7:0] op=command[47:40],object=command[39:32];
always @(posedge clk or posedge rst)begin
 if(rst)begin done<=0;response<=0;photo_valid<=0;movie_valid<=0;photo_op<=0;state<=0;catalog_delay<=0;catalog_height<=0;catalog_width<=0;end
 else begin
  done<=0;photo_valid<=0;movie_valid<=0;
  case(state)
   0:if(valid)begin
    response<=0;done<=1;
    if(media_reset)response<={8'd8,32'd0};
    else if(op==1)begin
     if(object==7)response<={8'd0,12'd0,native_error,native_retries};
     else if(object==12)response<={8'd0,28'd0,native_speed_status,native_high_speed};
     else if(object[3:0]>=photo_count || movie)response<={8'd2,32'd0};
     else begin catalog_height<=0;catalog_delay<=2;state<=3;done<=0;end
    end else if(movie)begin
     if(object==4 || object==8)begin movie_valid<=1;state<=2;done<=0;end
     else response<={8'd3,32'd0};
    end else begin
     photo_op<=object==1?3'd1:object==2?3'd2:object==3?3'd0:object==4?3'd3:object==5?3'd5:3'd4;
     photo_valid<=1;state<=1;done<=0;
    end
   end
   1:if(photo_done)begin response<={photo_code,28'd0,photo_target};done<=1;state<=0;end
   2:begin response<={8'd1,command[31:0]};done<=1;state<=0;end
   3:if(catalog_delay==0)state<=4;else catalog_delay<=catalog_delay-1'b1;
   4:begin
    catalog_width<=catalog_data;
    if(catalog_ready)begin catalog_height<=1;catalog_delay<=2;state<=5;end
   end
   5:if(catalog_delay==0)state<=6;else catalog_delay<=catalog_delay-1'b1;
   6:begin
    // Data may be sampled while waiting, but only ready commits the response.
    // The mailbox consumes done on the following edge with this value stable.
    response<={8'd0,catalog_width,catalog_data};
    if(catalog_ready)begin done<=1;state<=0;end
   end
   default:state<=0;
  endcase
  if(state!=0 && media_reset)begin done<=1;response<={8'd8,32'd0};state<=0;end
 end
end
endmodule
