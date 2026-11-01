// BQG3 v4 fixed absolute-state protocol, no relative actions and no media data.
// Transport ACK means received, NEVER frame-boundary applied. Actual application
// is carried by the peer's local_state snapshot. Nonces are freshness tags, not
// cryptographic/reboot-persistent replay protection.
module bq_state_link #(parameter BOARD_ID=1,parameter CLK_HZ=50000000,
 parameter SNAPSHOT_MS=50,parameter RETRY_MS=10,parameter STALE_MS=250)(
 input clk,input rst_n,input physical_link,
 input [127:0] local_state,input local_state_commit,
 output reg [127:0] remote_state,output reg remote_update,
 output reg peer_online,output reg stale,
 output [367:0] tx_packet,output reg tx_valid,input tx_ready,
 input [367:0] rx_packet,input rx_valid,output rx_ready,
 output reg [31:0] tx_count,output reg [31:0] rx_count,
 output reg [31:0] reject_count,output reg [31:0] retry_count);
 localparam PEER_ID=(BOARD_ID==1)?2:1;
 reg [31:0] cycles,local_nonce,peer_nonce,sequence_no,rx_sequence;
 reg [367:0] tx_image;
 wire [31:0] pending_seq=sequence_no,ack_sequence=rx_sequence;
 // ACK/HELLO bodies are ignored. Pending state remains stable while TX is busy.
 assign tx_packet={tx_image[367:240],(tx_image[327:320]==1?sequence_no:32'd0),tx_image[207:176],pending_state,tx_image[47:0]};
 reg [127:0] pending_state;
 localparam AGE_BITS=$clog2(STALE_MS+1);
 localparam SNAP_BITS=$clog2(SNAPSHOT_MS+1);
 localparam RETRY_BITS=$clog2(RETRY_MS+1);
 localparam MS_BITS=$clog2(CLK_HZ/1000+1);
 reg [AGE_BITS-1:0] age_ms;
 reg [SNAP_BITS-1:0] snapshot_ms;
 reg [RETRY_BITS-1:0] retry_ms;
 reg [MS_BITS-1:0] ms_div;
 reg link_d,have_peer,have_rx_seq,await_ack,dirty,ack_pending,hello_due,paused_d;
 reg [1:0] attempts;

 wire tick_ms=(ms_div==CLK_HZ/1000-1);
 wire [31:0] in_magic=rx_packet[367:336];
 wire [7:0] in_version=rx_packet[335:328],in_type=rx_packet[327:320];
 wire [7:0] in_source=rx_packet[319:312],in_flags=rx_packet[311:304];
 wire [31:0] in_nonce=rx_packet[303:272],in_echo=rx_packet[271:240];
 wire [31:0] in_seq=rx_packet[239:208],in_ack=rx_packet[207:176];
 wire [127:0] in_state=rx_packet[175:48];
 wire [31:0] seq_delta=in_seq-rx_sequence;
 wire format_ok=in_magic==32'h42514733&&in_version==8'd4&&in_source==PEER_ID&&
                in_flags==0&&rx_packet[47:0]==0;
 assign rx_ready=1'b1;
 function [367:0] pack;
 input [7:0] kind;input [31:0] seq,ack;input [127:0] body;
 begin pack={32'h42514733,8'd4,kind,(BOARD_ID==1?8'd1:8'd2),8'd0,local_nonce,
 peer_nonce,seq,ack,body,48'd0};end endfunction
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin
  cycles<=0;local_nonce<=0;peer_nonce<=0;sequence_no<=0;rx_sequence<=0;
  pending_state<=0;age_ms<=0;snapshot_ms<=0;retry_ms<=0;ms_div<=0;link_d<=0;
  have_peer<=0;have_rx_seq<=0;await_ack<=0;dirty<=1;ack_pending<=0;hello_due<=1;paused_d<=0;
  attempts<=0;remote_state<=0;remote_update<=0;peer_online<=0;stale<=1;
  tx_image<=0;tx_valid<=0;tx_count<=0;rx_count<=0;reject_count<=0;retry_count<=0;
 end else begin
  cycles<=cycles+1'b1;link_d<=physical_link;remote_update<=0;paused_d<=local_state[79];
  if(tick_ms)ms_div<=0;else ms_div<=ms_div+1'b1;
  if(tx_valid&&tx_ready)begin tx_valid<=0;tx_count<=tx_count+1'b1;end
  if(tick_ms)begin
   if(snapshot_ms==SNAPSHOT_MS-1)begin snapshot_ms<=0;dirty<=1;hello_due<=1;end
   else snapshot_ms<=snapshot_ms+1'b1;
   if(retry_ms<RETRY_MS)retry_ms<=retry_ms+1'b1;
   if(age_ms<STALE_MS)age_ms<=age_ms+1'b1;
   else if(!stale)begin
    stale<=1;peer_online<=0;have_peer<=0;have_rx_seq<=0;await_ack<=0;
    local_nonce<=cycles^(32'hb1700000+BOARD_ID);hello_due<=1;
   end
  end
  if(!physical_link)begin
   peer_online<=0;stale<=1;have_peer<=0;have_rx_seq<=0;await_ack<=0;
   ack_pending<=0;tx_valid<=0;dirty<=1;hello_due<=1;age_ms<=0;
  end else if(!link_d)begin
   local_nonce<=cycles^(32'hb1700000+BOARD_ID);peer_nonce<=0;
   sequence_no<=0;hello_due<=1;dirty<=1;
  end else begin
   // Transmission arbitration: handshake, receipt ACK, latest state, retry.
   if(!tx_valid||tx_ready)begin
    if(!peer_online&&hello_due)begin
     tx_image<=pack(8'd3,32'd0,32'd0,local_state);tx_valid<=1;hello_due<=0;
    end else if(ack_pending&&have_peer)begin
     tx_image<=pack(8'd2,32'd0,ack_sequence,local_state);tx_valid<=1;ack_pending<=0;
    end else if(peer_online&&dirty)begin
     sequence_no<=sequence_no+1'b1;pending_state<=local_state;
     tx_image<=pack(8'd1,sequence_no+1'b1,32'd0,local_state);tx_valid<=1;
     dirty<=0;await_ack<=1;attempts<=0;retry_ms<=0;
    end else if(peer_online&&await_ack&&retry_ms>=RETRY_MS)begin
     if(attempts<3)begin
      tx_image<=pack(8'd1,pending_seq,32'd0,pending_state);tx_valid<=1;
      attempts<=attempts+1'b1;retry_count<=retry_count+1'b1;
     end else await_ack<=0;
     retry_ms<=0;
    end
   end
   if(rx_valid)begin
    if(!format_ok)reject_count<=reject_count+1'b1;
    else if(in_type==3)begin
     if(!have_peer||peer_nonce!=in_nonce)begin
      peer_nonce<=in_nonce;have_peer<=1;have_rx_seq<=0;peer_online<=0;
      stale<=1;await_ack<=0;hello_due<=1;dirty<=1;
     end else if(in_echo==local_nonce)begin peer_online<=1;dirty<=1;end
    end else if(have_peer&&in_nonce==peer_nonce&&in_echo==local_nonce)begin
     if(in_type==1)begin
      if(!have_rx_seq||(!seq_delta[31]&&seq_delta!=0))begin
       peer_online<=1;age_ms<=0;stale<=0;ack_pending<=1;
       remote_state<=in_state;remote_update<=1;rx_sequence<=in_seq;have_rx_seq<=1;
       rx_count<=rx_count+1'b1;
      end else if(in_seq==rx_sequence&&in_state==remote_state)begin
       peer_online<=1;age_ms<=0;stale<=0;ack_pending<=1;
      end else reject_count<=reject_count+1'b1;
     end else if(in_type==2)begin
      if(await_ack&&in_ack==pending_seq)await_ack<=0;
     end else reject_count<=reject_count+1'b1;
    end else reject_count<=reject_count+1'b1;
   end
  end
  // A simultaneous application update has priority over clearing dirty.
  if(local_state_commit||paused_d!=local_state[79])dirty<=1;
 end
endmodule
