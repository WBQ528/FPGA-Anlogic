// R2-02: bundled-data request/ack, both cached owners held through transition.
// Geometry compositor consumes phase 0..32; no black fade multiplier.
// First valid image appears immediately. No target is accepted until prepared.
module photo_transition_commit #(parameter ENABLE=1)(
 input sd_clk,video_clk,rst_sd,rst_video,input requested_valid,frame_req,
 input [1:0] requested_buffer,requested_image,input [1:0] effect,
 output commit_ack,output reg active_valid,
 output reg [1:0] active_buffer,active_image,output reg [4:0] fade,
 output transition_busy,output [1:0] target_buffer,target_image,
 output reg [1:0] active_effect,output reg [5:0] progress
);
reg [4:0] held,pending;reg req_toggle,ack_toggle;
reg [1:0] req_sync,ack_sync;reg seen,pending_toggle,pending_valid,frame_d;
reg [1:0] phase;
assign transition_busy=phase!=0;
assign target_buffer=phase!=0?pending[3:2]:active_buffer;
assign target_image=phase!=0?pending[1:0]:active_image;
wire [4:0] request={requested_valid,requested_buffer,requested_image};
assign commit_ack=(ack_sync[1]==req_toggle) && held==request;
always @(posedge sd_clk or posedge rst_sd)begin
 if(rst_sd)begin held<=0;req_toggle<=0;ack_sync<=0;end
 else begin
  ack_sync<={ack_sync[0],ack_toggle};
  if(ack_sync[1]==req_toggle && held!=request)begin held<=request;req_toggle<=~req_toggle;end
 end
end
always @(posedge video_clk or posedge rst_video)begin
 if(rst_video)begin
  pending<=0;req_sync<=0;seen<=0;pending_toggle<=0;pending_valid<=0;
  ack_toggle<=0;frame_d<=0;active_valid<=0;active_buffer<=0;active_image<=0;fade<=16;phase<=0;
  progress<=0;active_effect<=0;
 end else begin
  req_sync<={req_sync[0],req_toggle};frame_d<=frame_req;
  if(req_sync[1]!=seen)begin
   pending<=held;pending_toggle<=req_sync[1];seen<=req_sync[1];pending_valid<=1;
  end
  if(frame_req && !frame_d)begin
   case(phase)
    0:if(pending_valid)begin
     if(!ENABLE || !active_valid || !pending[4] || pending[3:0]=={active_buffer,active_image})begin
      {active_valid,active_buffer,active_image}<=pending;
      pending_valid<=0;ack_toggle<=pending_toggle;fade<=16;
     end else begin phase<=1;progress<=0;active_effect<=effect;end
    end
    1:if(progress<32)progress<=progress+1'b1;
      else begin
       {active_valid,active_buffer,active_image}<=pending;
       phase<=0;pending_valid<=0;ack_toggle<=pending_toggle;progress<=0;
      end
    default:begin phase<=0;fade<=16;end
   endcase
  end
 end
end
endmodule
