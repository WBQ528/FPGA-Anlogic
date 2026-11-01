// Fixed 64-byte (including FCS) local Ethernet frames only, no VLAN/jumbo/IP.
// Nibble interface is MII-style 25MHz, low nibble first. No packet RAM/DSP.
module bq_mac_tx100 #(parameter [47:0] LOCAL_MAC=48'h024251000001,
 parameter [47:0] PEER_MAC=48'h024251000002)(
 input clk,input rst_n,input [367:0] packet,input valid,output ready,
 output reg [3:0] txd,output reg tx_en,output reg sent);
 // Upstream stable-bundle mailbox retains packet until the last nibble is sent.
 wire [367:0] payload=packet;
 reg [7:0] nibble_index;
 reg [4:0] gap;
 reg active;
 reg [31:0] crc;
 wire [6:0] byte_index=nibble_index[7:1];
 wire [5:0] payload_byte=7'd67-byte_index;
 reg [7:0] byte_value;
 reg [3:0] nibble_value;
 integer k;
 function [31:0] crc4;
 input [31:0] c;input [3:0] d;reg [31:0] r;integer i;
 begin r=c;for(i=0;i<4;i=i+1)begin
 if(r[0]^d[i])r=(r>>1)^32'hedb88320;else r=r>>1;
 end crc4=r;end endfunction
 always @*begin
  byte_value=0;
  if(byte_index<7)byte_value=8'h55;
  else if(byte_index==7)byte_value=8'hd5;
  else if(byte_index<14)byte_value=PEER_MAC>>(8*(13-byte_index));
  else if(byte_index<20)byte_value=LOCAL_MAC>>(8*(19-byte_index));
  else if(byte_index==20)byte_value=8'h88;
  else if(byte_index==21)byte_value=8'hb5;
  else if(byte_index<68)byte_value=payload>>(payload_byte*8);
  // FCS is complemented CRC, least significant nibble first.
  if(byte_index>=68)nibble_value=~crc[3:0];
  else if(nibble_index[0])nibble_value=byte_value[7:4];
  else nibble_value=byte_value[3:0];
 end
 assign ready=active&&(nibble_index==143);
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin nibble_index<=0;gap<=0;active<=0;
 crc<=32'hffffffff;txd<=0;tx_en<=0;sent<=0;end
 else begin
  sent<=0;tx_en<=0;txd<=0;
  if(gap!=0)gap<=gap-1'b1;
  if(valid&&!active&&gap==0)begin active<=1;nibble_index<=0;crc<=32'hffffffff;end
  if(active)begin
   tx_en<=1;txd<=nibble_value;
   if(byte_index>=8&&byte_index<68)crc<=crc4(crc,nibble_value);
   if(byte_index>=68)crc<={4'd0,crc[31:4]};
   if(nibble_index==143)begin active<=0;gap<=24;sent<=1;end
   else nibble_index<=nibble_index+1'b1;
  end
 end
endmodule

module bq_mac_rx100 #(parameter [47:0] LOCAL_MAC=48'h024251000002,
 parameter [47:0] PEER_MAC=48'h024251000001)(
 input clk,input rst_n,input [3:0] rxd,input rx_dv,input rx_er,
 output [367:0] packet,output reg valid,input ready,
 output reg bad_frame,output reg overflow);
 reg in_frame,half,found_sfd,invalid,drop_frame;
 reg [3:0] low_nibble;
 reg [3:0] preamble;
 reg [7:0] byte_count;
 reg [31:0] crc;
 reg [367:0] staging;
 assign packet=staging;
 wire [7:0] octet={rxd,low_nibble};
 reg [7:0] expected;
 function [31:0] crc4;
 input [31:0] c;input [3:0] d;reg [31:0] r;integer i;
 begin r=c;for(i=0;i<4;i=i+1)begin
 if(r[0]^d[i])r=(r>>1)^32'hedb88320;else r=r>>1;
 end crc4=r;end endfunction
 always @*begin
  expected=0;
  if(byte_count<6)expected=LOCAL_MAC>>(8*(5-byte_count));
  else if(byte_count<12)expected=PEER_MAC>>(8*(11-byte_count));
  else if(byte_count==12)expected=8'h88;
  else if(byte_count==13)expected=8'hb5;
 end
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin
  in_frame<=0;half<=0;found_sfd<=0;invalid<=0;drop_frame<=0;low_nibble<=0;
  preamble<=0;byte_count<=0;crc<=32'hffffffff;staging<=0;
  valid<=0;bad_frame<=0;overflow<=0;
 end else begin
  bad_frame<=0;overflow<=0;
  if(valid&&ready)valid<=0;
  if(rx_dv)begin
   in_frame<=1;half<=~half;low_nibble<=rxd;
   if(!in_frame)drop_frame<=valid&&!ready;
   if(rx_er)invalid<=1;
   if(found_sfd)crc<=crc4(crc,rxd);
   if(half)begin
    if(!found_sfd)begin
     if(octet==8'h55&&preamble<7)preamble<=preamble+1'b1;
     else if(octet==8'hd5&&preamble==7)begin found_sfd<=1;byte_count<=0;end
     else invalid<=1;
    end else begin
     if(byte_count<14&&octet!=expected)invalid<=1;
     if(byte_count>=14&&byte_count<60&&!drop_frame)staging<={staging[359:0],octet};
     if(byte_count<255)byte_count<=byte_count+1'b1;
     else invalid<=1;
    end
   end
  end else if(in_frame)begin
   if(found_sfd&&!half&&!invalid&&byte_count==64&&crc==32'hdebb20e3)begin
    if(!drop_frame)begin valid<=1;end
    else overflow<=1;
   end else bad_frame<=1;
   in_frame<=0;half<=0;found_sfd<=0;invalid<=0;preamble<=0;
   byte_count<=0;crc<=32'hffffffff;
  end
 end
endmodule
