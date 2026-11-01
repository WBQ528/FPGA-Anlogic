// full-duplex gigabit MAC for the bounded control protocol. One octet
// per 125MHz clock. Full preamble/SFD, 60-byte body, IEEE FCS, >=12-byte IFG.
module bq_mac_tx1000 #(parameter [47:0] LOCAL_MAC=48'h024251000001,
 parameter [47:0] PEER_MAC=48'h024251000002)(
 input clk,rst_n,input [367:0] packet,input valid,output ready,
 output reg [7:0] txd,output reg tx_en,output reg sent);
reg [5:0] payload_index;
reg [6:0] index;reg [3:0] gap;reg active;reg [31:0] crc;
reg [7:0] octet_q;reg data_valid,body_q,fcs_q,last_q;
reg valid_a,body_a,fcs_a,last_a;reg [3:0] group_a;
reg [7:0] lane_q[0:8];
function [31:0] crc8;input [31:0] c;input [7:0] d;reg [31:0] r;integer i;
 begin r=c;for(i=0;i<8;i=i+1)r=(r>>1)^((r[0]^d[i])?32'hedb88320:32'd0);crc8=r;end
endfunction
// Each first-stage mux selects only eight constant-position bytes. This
// avoids a variable 368-bit shift plus header priority in the 8 ns path.
reg [7:0] lane0;
always @*case(index[2:0])
3'd0:lane0=8'h55;
3'd1:lane0=8'h55;
3'd2:lane0=8'h55;
3'd3:lane0=8'h55;
3'd4:lane0=8'h55;
3'd5:lane0=8'h55;
3'd6:lane0=8'h55;
3'd7:lane0=8'hd5;
endcase
always @(posedge clk)lane_q[0]<=lane0;
reg [7:0] lane1;
always @*case(index[2:0])
3'd0:lane1=PEER_MAC[40+:8];
3'd1:lane1=PEER_MAC[32+:8];
3'd2:lane1=PEER_MAC[24+:8];
3'd3:lane1=PEER_MAC[16+:8];
3'd4:lane1=PEER_MAC[8+:8];
3'd5:lane1=PEER_MAC[0+:8];
3'd6:lane1=LOCAL_MAC[40+:8];
3'd7:lane1=LOCAL_MAC[32+:8];
endcase
always @(posedge clk)lane_q[1]<=lane1;
reg [7:0] lane2;
always @*case(index[2:0])
3'd0:lane2=LOCAL_MAC[24+:8];
3'd1:lane2=LOCAL_MAC[16+:8];
3'd2:lane2=LOCAL_MAC[8+:8];
3'd3:lane2=LOCAL_MAC[0+:8];
3'd4:lane2=8'h88;
3'd5:lane2=8'hb5;
3'd6:lane2=packet[360+:8];
3'd7:lane2=packet[352+:8];
endcase
always @(posedge clk)lane_q[2]<=lane2;
reg [7:0] lane3;
always @*case(index[2:0])
3'd0:lane3=packet[344+:8];
3'd1:lane3=packet[336+:8];
3'd2:lane3=packet[328+:8];
3'd3:lane3=packet[320+:8];
3'd4:lane3=packet[312+:8];
3'd5:lane3=packet[304+:8];
3'd6:lane3=packet[296+:8];
3'd7:lane3=packet[288+:8];
endcase
always @(posedge clk)lane_q[3]<=lane3;
reg [7:0] lane4;
always @*case(index[2:0])
3'd0:lane4=packet[280+:8];
3'd1:lane4=packet[272+:8];
3'd2:lane4=packet[264+:8];
3'd3:lane4=packet[256+:8];
3'd4:lane4=packet[248+:8];
3'd5:lane4=packet[240+:8];
3'd6:lane4=packet[232+:8];
3'd7:lane4=packet[224+:8];
endcase
always @(posedge clk)lane_q[4]<=lane4;
reg [7:0] lane5;
always @*case(index[2:0])
3'd0:lane5=packet[216+:8];
3'd1:lane5=packet[208+:8];
3'd2:lane5=packet[200+:8];
3'd3:lane5=packet[192+:8];
3'd4:lane5=packet[184+:8];
3'd5:lane5=packet[176+:8];
3'd6:lane5=packet[168+:8];
3'd7:lane5=packet[160+:8];
endcase
always @(posedge clk)lane_q[5]<=lane5;
reg [7:0] lane6;
always @*case(index[2:0])
3'd0:lane6=packet[152+:8];
3'd1:lane6=packet[144+:8];
3'd2:lane6=packet[136+:8];
3'd3:lane6=packet[128+:8];
3'd4:lane6=packet[120+:8];
3'd5:lane6=packet[112+:8];
3'd6:lane6=packet[104+:8];
3'd7:lane6=packet[96+:8];
endcase
always @(posedge clk)lane_q[6]<=lane6;
reg [7:0] lane7;
always @*case(index[2:0])
3'd0:lane7=packet[88+:8];
3'd1:lane7=packet[80+:8];
3'd2:lane7=packet[72+:8];
3'd3:lane7=packet[64+:8];
3'd4:lane7=packet[56+:8];
3'd5:lane7=packet[48+:8];
3'd6:lane7=packet[40+:8];
3'd7:lane7=packet[32+:8];
endcase
always @(posedge clk)lane_q[7]<=lane7;
reg [7:0] lane8;
always @*case(index[2:0])
3'd0:lane8=packet[24+:8];
3'd1:lane8=packet[16+:8];
3'd2:lane8=packet[8+:8];
3'd3:lane8=packet[0+:8];
3'd4:lane8=8'd0;
3'd5:lane8=8'd0;
3'd6:lane8=8'd0;
3'd7:lane8=8'd0;
endcase
always @(posedge clk)lane_q[8]<=lane8;
assign ready=data_valid && last_q;
always @(posedge clk or negedge rst_n)
 if(!rst_n)begin payload_index<=45;index<=0;gap<=0;active<=0;crc<=32'hffffffff;txd<=0;tx_en<=0;sent<=0;octet_q<=0;data_valid<=0;valid_a<=0;body_a<=0;fcs_a<=0;last_a<=0;group_a<=0;body_q<=0;fcs_q<=0;last_q<=0;end
 else begin
  txd<=0;tx_en<=0;sent<=0;valid_a<=active;data_valid<=valid_a;
  if(gap!=0)gap<=gap-1'b1;
  if(valid && !active && !valid_a && !data_valid && gap==0)begin active<=1;index<=0;payload_index<=45;crc<=32'hffffffff;end
  begin
   // Separate payload selection from CRC feedback at 125MHz. The original
   // combined byte mux/subtract/CRC path missed the 8ns period in routed TD.
   group_a<=index[6:3];octet_q<=lane_q[group_a];
   body_a<=index>=8 && index<68;fcs_a<=index>=68;last_a<=index==71;
   body_q<=body_a;fcs_q<=fcs_a;last_q<=last_a;
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
// Payload is meaningful only with valid. A complete accepted 46-byte payload
// overwrites every bit before publication. Keeping data flops off the reset
// tree lets the fabric pack them with the shift/enable logic; control and CRC
// still reset immediately, so a partial pre-reset packet cannot be published.
always @(posedge clk)
 if(rst_n && rx_dv && found_sfd && payload_active && !drop_frame)
  staging<={staging[359:0],rxd};
function [31:0] crc8;input [31:0] c;input [7:0] d;reg [31:0] r;integer i;
 begin r=c;for(i=0;i<8;i=i+1)r=(r>>1)^((r[0]^d[i])?32'hedb88320:32'd0);crc8=r;end
endfunction
always @(posedge clk or negedge rst_n)
 if(!rst_n)begin in_frame<=0;found_sfd<=0;invalid<=0;drop_frame<=0;preamble<=0;byte_count<=0;crc<=32'hffffffff;valid<=0;bad_frame<=0;overflow<=0;header_cursor<=0;header_bad_q<=0;payload_active<=0;end
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
