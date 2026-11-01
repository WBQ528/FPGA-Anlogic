// Common A/B caption endpoint. Glyph and configuration commits both cross into
// the video domain only at frame boundaries; GETs report acknowledged values.
module bq_caption_endpoint(
 input clk,rst,valid,input [2:0] operation,input [31:0] value,
 output reg done,output reg [7:0] code,output reg [31:0] result,
 input video_clk,video_rst,frame_start,input [9:0] row_address,
 output [31:0] row_bits,output [5:0] visible_count,output [15:0] visible_epoch,
 output [15:0] applied_epoch,output [5:0] applied_count,
 output [15:0] display_serial,
 output reg [8:0] visible_settings,output reg [8:0] applied_settings
);
 localparam [8:0] DEFAULT_SETTINGS={6'd4,2'd1,1'b1};
 reg waiting,cfg_request,cfg_ack,cfg_seen,applied_seen;
 reg [8:0] held_settings;
 (* ASYNC_REG="TRUE" *) reg [1:0] cfg_req_sync,cfg_ack_sync;
 // Keep the acknowledgement pending until the system-domain readback has
 // caught up as well; accepting a reversal in that last cycle must not mistake
 // the previous value for the value currently displayed.
 wire cfg_pending=cfg_request!=cfg_ack_sync[1] || cfg_ack_sync[1]!=applied_seen;
 wire store_valid=valid && !waiting && operation<4;
 wire store_done;wire [7:0] store_code;wire [31:0] store_result;
 bq_caption_store store(.clk(clk),.rst(rst),.valid(store_valid),.operation(operation[1:0]),.value(value),
  .done(store_done),.code(store_code),.result(store_result),.video_clk(video_clk),.video_rst(video_rst),
  .frame_start(frame_start),.row_address(row_address),.row_bits(row_bits),
  .visible_count(visible_count),.visible_epoch(visible_epoch),.applied_epoch(applied_epoch),.applied_count(applied_count),.display_serial(display_serial));
 always @(posedge clk or posedge rst)begin
  if(rst)begin
   waiting<=0;done<=0;code<=0;result<=0;cfg_request<=0;cfg_ack_sync<=0;applied_seen<=0;
   held_settings<=DEFAULT_SETTINGS;applied_settings<=DEFAULT_SETTINGS;
  end else begin
   cfg_ack_sync<={cfg_ack_sync[0],cfg_ack};done<=0;
   if(cfg_ack_sync[1]!=applied_seen)begin applied_settings<=held_settings;applied_seen<=cfg_ack_sync[1];end
   if(waiting && store_done)begin waiting<=0;done<=1;code<=store_code;result<=store_result;end
   if(valid && !waiting)begin
    code<=0;result<=0;
    if(operation<4)waiting<=1;
    else begin
     done<=1;
     case(operation)
      4:begin
       if(value[31:9]!=0 || value[8:3]==0 || value[8:3]>32 || value[2:1]==3)code<=2;
       else if(cfg_pending)begin code<=value[8:0]==held_settings?8'd1:8'd8;result<={23'd0,held_settings};end
       else if(value[8:0]==applied_settings)result<={23'd0,applied_settings};
       else begin held_settings<=value[8:0];cfg_request<=~cfg_request;code<=1;result<=value;end
      end
      5:result<={22'd0,cfg_pending,applied_settings};
      default:code<=3;
     endcase
    end
   end
  end
 end
 always @(posedge video_clk or posedge video_rst)begin
  if(video_rst)begin cfg_req_sync<=0;cfg_seen<=0;cfg_ack<=0;visible_settings<=DEFAULT_SETTINGS;end
  else begin
   cfg_req_sync<={cfg_req_sync[0],cfg_request};
   if(frame_start && cfg_req_sync[1]!=cfg_seen)begin
    visible_settings<=held_settings;cfg_seen<=cfg_req_sync[1];cfg_ack<=cfg_req_sync[1];
   end
  end
 end
endmodule
