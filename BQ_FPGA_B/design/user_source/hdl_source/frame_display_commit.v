// Bundled-data handshake: payload held stable until frame-boundary ACK returns.
module frame_display_commit #(parameter BUFFER_BITS=1)(
 input sd_clk,video_clk,rst_sd,rst_video,
 input requested_valid,frame_req,
 input [BUFFER_BITS-1:0] requested_buffer,
 input [1:0] requested_image,
 output commit_ack,active_valid,output [BUFFER_BITS-1:0] active_buffer,output [1:0] active_image
);
frame_bundle_commit #(.WIDTH(3+BUFFER_BITS)) bundle(
 .source_clk(sd_clk),.dest_clk(video_clk),.source_rst(rst_sd),.dest_rst(rst_video),
 .requested({requested_valid,requested_buffer,requested_image}),.frame_req(frame_req),
 .commit_ack(commit_ack),.active({active_valid,active_buffer,active_image}));
endmodule
module frame_bundle_commit #(parameter WIDTH=4)(
 input source_clk,dest_clk,source_rst,dest_rst,
 input [WIDTH-1:0] requested,input frame_req,
 output commit_ack,output reg [WIDTH-1:0] active,
 output reg [WIDTH-1:0] source_active,output transfer_idle
);
reg [WIDTH-1:0] held,pending;
reg request_toggle,ack_toggle;
reg [1:0] req_sync,ack_sync;
reg seen_toggle,pending_toggle,pending_valid,frame_d;
assign commit_ack=(ack_sync[1]==request_toggle) && (held==requested);
// Ownership returned from the displayed frame, independent of newer animated
// state. Equality with requested is unsuitable for continuously moving media.
assign transfer_idle=(ack_sync[1]==request_toggle);
always @(posedge source_clk or posedge source_rst)
 if(source_rst)begin held<=0;request_toggle<=0;ack_sync<=0;source_active<=0;end
 else begin
  ack_sync<={ack_sync[0],ack_toggle};
  // The held bundle has actually reached a display frame once its ACK returns.
  // On a simultaneous new request this captures OLD held, not the new payload.
  if(ack_sync[1]==request_toggle)source_active<=held;
  if(ack_sync[1]==request_toggle && held!=requested)begin
   held<=requested;request_toggle<=~request_toggle;
  end
 end
always @(posedge dest_clk or posedge dest_rst)
 if(dest_rst)begin
  req_sync<=0;seen_toggle<=0;pending<=0;pending_toggle<=0;
  pending_valid<=0;active<=0;ack_toggle<=0;frame_d<=0;
 end else begin
  req_sync<={req_sync[0],request_toggle};frame_d<=frame_req;
  if(req_sync[1]!=seen_toggle)begin
   pending<=held;pending_toggle<=req_sync[1];seen_toggle<=req_sync[1];pending_valid<=1;
  end
  if(frame_req && !frame_d && pending_valid)begin
   active<=pending;ack_toggle<=pending_toggle;pending_valid<=0;
  end
 end
endmodule
module reset_release(input clk,arst,output rst);
reg [2:0] pipe;
always @(posedge clk or posedge arst)
 if(arst)pipe<=3'b111;else pipe<={pipe[1:0],1'b0};
assign rst=pipe[2];
endmodule
