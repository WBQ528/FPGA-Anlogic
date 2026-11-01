// coherent A media snapshots; no free-running extrapolation of the route.
// Local control: [67:66] page 0 map/1 garden/2 itinerary; [65] free browsing;
// [63:60] local POI 1..4; [59:56] local photo 0..2; [31:16] revision; CB73.
module b_scene_control #(parameter SD_HZ=100000000,parameter COVER_ENABLE=0)(
 input net_clk,net_rst,remote_update,remote_stale,input [127:0] remote_state,
 output [127:0] applied_state,output applied_update,
 input sd_clk,sd_rst,video_clk,video_rst,frame_request,input transition_busy,
 input map_valid,photo_valid,input [1:0] photo_bank,input [3:0] photo_asset,input [3:0] local_error,
 input [10:0] photo_width,photo_height,
 output reg [3:0] desired_asset,output display_ack,output reg [1:0] protected_bank,
 output [127:0] video_state,output video_map_valid,video_photo_valid,output [1:0] video_photo_bank,
 output [10:0] video_photo_width,video_photo_height,output [31:0] animation_ms
);
reg stale_d;
always @(posedge net_clk or posedge net_rst)if(net_rst)stale_d<=1;else stale_d<=remote_stale;
wire incoming;wire [128:0] bundle;
b_state_mailbox #(.WIDTH(129)) receive(.source_clk(net_clk),.source_rst(net_rst),.update(remote_update || stale_d!=remote_stale),.data({remote_stale,remote_state}),
 .dest_clk(sd_clk),.dest_rst(sd_rst),.valid(incoming),.received(bundle));
reg [127:0] state;reg stale;reg [16:0] millisecond;reg [31:0] anim;
wire frozen=state[79] || stale;
wire [3:0] requested_poi=state[65] ? state[63:60]:(state[71:68]>=1 && state[71:68]<=4 ? state[71:68]:4'd1);
function [3:0] asset;input [3:0] poi,index;begin case(poi)
 1:asset=index==0 ? 1:index==1 ? 5:6;
 2:asset=index==0 ? 2:index==1 ? 7:8;
 3:asset=index==0 ? 3:index==1 ? 9:10;
 default:asset=index==0 ? 4:index==1 ? 11:12;
endcase end endfunction
wire [3:0] desired_comb=state[65] ? asset(requested_poi,state[59:56]):
 asset(requested_poi,0);
always @(posedge sd_clk or posedge sd_rst)begin
 if(sd_rst)begin state<=128'h0;state[79]<=1;state[71:68]<=1;state[63:60]<=1;state[15:0]<=16'hcb74;stale<=1;millisecond<=0;anim<=0;end
 else begin
  if(incoming)begin
   if(bundle[15:0]==16'hcb74)begin state<=bundle[127:0];stale<=bundle[128];end else stale<=1;
  end
  if(millisecond==SD_HZ/1000-1)begin millisecond<=0;if(!frozen)anim<=anim+1'b1;end
  else millisecond<=millisecond+1'b1;
 end
end
always @(posedge sd_clk or posedge sd_rst)if(sd_rst)desired_asset<=1;else desired_asset<=desired_comb;
// Match the SAME state used to build the outgoing frame. desired_asset is a
// registered loader request and trails a new page selection by one clock.
wire asset_ready=photo_valid && photo_asset==desired_comb;
reg [185:0] requested;wire [185:0] active,committed_source;wire frame_ack;
reg [15:0] frame_ack_delayed;
(* ASYNC_REG="TRUE" *) reg [2:0] cover_sync;
always @(posedge sd_clk or posedge sd_rst)
 if(sd_rst)begin frame_ack_delayed<=0;cover_sync<=0;end
 else begin frame_ack_delayed<={frame_ack_delayed[14:0],frame_ack};cover_sync<={cover_sync[1:0],transition_busy};end
// An animated bundle may start another transfer immediately after its ACK.
// Delay that ownership event for CDC settling; requiring 16 consecutive idle
// clocks would suppress every ACK while the media/animation clock advances.
assign display_ack=frame_ack_delayed[15] && committed_source[129:128]==photo_bank &&
 (!COVER_ENABLE || !(|cover_sync));
always @(posedge sd_clk or posedge sd_rst)begin
 if(sd_rst)begin requested<=0;protected_bank<=0;end
 else begin
  // Garden pages retain the last complete page until the new texture is ready.
  if(state[67:66]!=1 || asset_ready)begin
   requested<={photo_width,photo_height,anim,map_valid,asset_ready,photo_bank,state};
   requested[77]<=map_valid && (state[67:66]!=1 || asset_ready);
   requested[71:68]<=requested_poi;requested[75:72]<=desired_comb-1'b1;

  end
  // Error feedback must not wait for the failed picture or new revision.
  requested[35:32]<=local_error;
  requested[79]<=frozen;protected_bank<=committed_source[129:128];
 end
end
frame_bundle_commit #(.WIDTH(186)) commit(.source_clk(sd_clk),.dest_clk(video_clk),.source_rst(sd_rst),.dest_rst(video_rst),
 .requested(requested),.frame_req(frame_request),.commit_ack(),.transfer_idle(frame_ack),.active(active),.source_active(committed_source));
assign video_state=active[127:0];assign video_photo_bank=active[129:128];assign video_photo_valid=active[130];assign video_map_valid=active[131];
assign animation_ms=active[163:132];assign video_photo_height=active[174:164];assign video_photo_width=active[185:175];
reg frame_d;always @(posedge video_clk or posedge video_rst)if(video_rst)frame_d<=0;else frame_d<=frame_request;
b_state_mailbox #(.WIDTH(128)) report(.source_clk(video_clk),.source_rst(video_rst),.update(frame_d && !frame_request),.data(video_state),
 .dest_clk(net_clk),.dest_rst(net_rst),.valid(applied_update),.received(applied_state));
endmodule
