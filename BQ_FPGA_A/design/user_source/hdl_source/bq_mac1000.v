// full-duplex gigabit MAC for the bounded control protocol. One octet
// per 125MHz clock. Full preamble/SFD, 60-byte body, IEEE FCS, >=12-byte IFG.
module bq_mac_tx1000 #(parameter [47:0] LOCAL_MAC=48'h024251000001,
 parameter [47:0] PEER_MAC=48'h024251000002)(
 input clk,rst_n,input [367:0] packet,input valid,output ready,
 output reg [7:0] txd,output reg tx_en,output reg sent);
reg [5:0] payload_index;
reg [6:0] index;reg [3:0] gap;reg active;reg [31:0] crc;
reg [7:0] octet;
reg [7:0] octet_q;reg data_valid,body_q,fcs_q,last_q;
function [31:0] crc8;input [31:0] c;input [7:0] d;reg [31:0] r;integer i;
 begin r=c;for(i=0;i<8;i=i+1)r=(r>>1)^((r[0]^d[i])?32'hedb88320:32'd0);crc8=r;end
endfunction
always @*begin
 if(index<7)octet=8'h55;
 else if(index==7)octet=8'hd5;
 else if(index<14)octet=PEER_MAC>>(8*(13-index));
 else if(index<20)octet=LOCAL_MAC>>(8*(19-index));
 else if(index==20)octet=8'h88;
 else if(index==21)octet=8'hb5;
 else if(index<68)octet=packet>>{payload_index,3'b000};
 else octet=0;
end
assign ready=data_valid && last_q;
always @(posedge clk or negedge rst_n)
 if(!rst_n)begin payload_index<=45;index<=0;gap<=0;active<=0;crc<=32'hffffffff;txd<=0;tx_en<=0;sent<=0;octet_q<=0;data_valid<=0;body_q<=0;fcs_q<=0;last_q<=0;end
 else begin
  txd<=0;tx_en<=0;sent<=0;data_valid<=active;
  if(gap!=0)gap<=gap-1'b1;
  if(valid && !active && !data_valid && gap==0)begin active<=1;index<=0;payload_index<=45;crc<=32'hffffffff;end
  begin
   // Separate payload selection from CRC feedback at 125MHz. The original
   // combined byte mux/subtract/CRC path missed the 8ns period in routed TD.
   octet_q<=octet;body_q<=index>=8 && index<68;fcs_q<=index>=68;last_q<=index==71;
   // Separate the descending payload cursor from byte selection.
   // The old 67-index subtract sat before a 368-bit mux at 125 MHz.
   if(active && index>=22 && index<67)payload_index<=payload_index-1'b1;
   if(active)begin if(index==71)active<=0;else index<=index+1'b1;end
  end
  if(data_valid)begin
   txd<=fcs_q?~crc[7:0]:octet_q;tx_en<=1;
   if(body_q)crc<=crc8(crc,octet_q);
   else if(fcs_q)crc<={8'd0,crc[31:8]};
   if(last_q)begin gap<=12;sent<=1;end
  end
 end
endmodule

module bq_mac_rx1000 #(parameter [47:0] LOCAL_MAC=48'h024251000002,
 parameter [47:0] PEER_MAC=48'h024251000001)(
 input clk,rst_n,input [7:0] rxd,input rx_dv,rx_er,
 output [367:0] packet,output reg valid,input ready,
 output reg bad_frame,overflow);
reg in_frame,found_sfd,invalid,drop_frame;reg [3:0] preamble;
reg [7:0] byte_count;reg [31:0] crc;reg [367:0] staging;
reg [13:0] header_cursor;reg header_bad_q,payload_active;
wire [111:0] expected_header={LOCAL_MAC,PEER_MAC,16'h88b5};
wire [13:0] header_mismatch;
genvar h;
generate for(h=0;h<14;h=h+1)begin:header_check
 assign header_mismatch[h]=header_cursor[h] && rxd!=expected_header[111-h*8-:8];
end endgenerate
assign packet=staging;
function [31:0] crc8;input [31:0] c;input [7:0] d;reg [31:0] r;integer i;
 begin r=c;for(i=0;i<8;i=i+1)r=(r>>1)^((r[0]^d[i])?32'hedb88320:32'd0);crc8=r;end
endfunction
always @(posedge clk or negedge rst_n)
 if(!rst_n)begin in_frame<=0;found_sfd<=0;invalid<=0;drop_frame<=0;preamble<=0;byte_count<=0;crc<=32'hffffffff;staging<=0;valid<=0;bad_frame<=0;overflow<=0;header_cursor<=0;header_bad_q<=0;payload_active<=0;end
 else begin
  bad_frame<=0;overflow<=0;header_bad_q<=0;if(valid && ready)valid<=0;
  if(header_bad_q)invalid<=1;
  if(rx_dv)begin
   in_frame<=1;if(!in_frame)drop_frame<=valid && !ready;
   if(rx_er)invalid<=1;
   if(!found_sfd)begin
    if(rxd==8'h55)begin if(preamble<7)preamble<=preamble+1'b1;end
    else if(rxd==8'hd5 && preamble!=0)begin found_sfd<=1;byte_count<=0;header_cursor<=14'd1;end
    else invalid<=1;
   end else begin
    crc<=crc8(crc,rxd);
    // One-hot header checking and a registered payload window avoid the old
    // variable byte shift / subtract / comparison on the 8ns RX path.
    header_bad_q<=|header_mismatch;header_cursor<={header_cursor[12:0],1'b0};
    if(byte_count==13)payload_active<=1;
    if(byte_count==59)payload_active<=0;
    if(payload_active && !drop_frame)staging<={staging[359:0],rxd};
    if(byte_count!=255)byte_count<=byte_count+1'b1;else invalid<=1;
   end
  end else if(in_frame)begin
   if(found_sfd && !invalid && !header_bad_q && byte_count==64 && crc==32'hdebb20e3)begin
    if(!drop_frame)valid<=1;else overflow<=1;
   end else bad_frame<=1;
   in_frame<=0;found_sfd<=0;invalid<=0;preamble<=0;byte_count<=0;crc<=32'hffffffff;header_cursor<=0;payload_active<=0;
  end
 end
endmodule
