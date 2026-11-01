// ordinary 18-byte requests plus bounded GB2312 text upload; MODBUS CRC covers bytes 0..15. One outstanding
// request. Replies are TJC assignments hrval, hrmeta, hrseq; hrseq commits last.
// New HELLO requires a new nonzero session. Only the immediately preceding
// identical request can be retried; actions are never replayed by retries.
module hmi_link #(parameter integer CLOCK_HZ=50000000,BAUD=115200,ALLOW_TEXT=0,
 parameter integer GAP_CYCLES=CLOCK_HZ/2000,TIMEOUT_CYCLES=CLOCK_HZ/50)(
 input clk,rst,rx,output tx,
 output reg command_valid,output [7:0] command_op,command_object,
 output [31:0] command_value,input command_done,input [7:0] command_code,
 input [31:0] command_result,
 // Text RAM is staging only. It is read by B after a validated command,
 // before command_done. A new frame cannot write it while a command is busy.
 input [5:0] text_address,output reg [7:0] text_data,
 output reg [15:0] crc_errors,framing_errors,busy_drops,session_id
);
wire rv,re,tbusy;wire [7:0] rd;reg ts;reg [7:0] td;
hmi_uart #(.CLOCK_HZ(CLOCK_HZ),.BAUD(BAUD)) uart(.clk(clk),.rst(rst),.rx(rx),.tx(tx),
 .rx_valid(rv),.rx_data(rd),.rx_error(re),.tx_start(ts),.tx_data(td),.tx_busy(tbusy));
function [15:0] crc16;input [15:0] c;input [7:0] d;reg [15:0] t;integer i;
 begin t=c^{8'd0,d};for(i=0;i<8;i=i+1)t=t[0]?(t>>1)^16'ha001:t>>1;crc16=t;end
endfunction
reg [8:0] ri;reg capture_text;
reg [7:0] text_ram[0:63];
always @(posedge clk)text_data<=text_ram[text_address];reg [$clog2(TIMEOUT_CYCLES+1)-1:0] timeout_count;
reg [15:0] crc,wire_crc,rsession,rseq;reg [7:0] version,target,rop,robj,rlen,rflags;
reg [31:0] rval;reg packet;
wire [8:0] payload_end=rflags[0] ? 9'd12+{1'b0,rlen} : 9'd16;
wire text_frame=ALLOW_TEXT!=0 && rop==8'h40 && robj==8'h40 && rflags==1 && rlen<=64;
wire [31:0] request_value=text_frame?{rlen,8'd0,wire_crc}:rval;
reg [3:0] native_left;reg [7:0] native_type,last_screen_result;
reg [15:0] screen_results;reg native_text;reg [6:0] native_text_count;reg [1:0] native_ff;
reg screen_boot;
function is_result;input [7:0] b;begin
 case(b)
  8'h00,8'h01,8'h02,8'h03,8'h04,8'h05,8'h06,8'h09,8'h11,8'h12,8'h1a,8'h1b,8'h1c,8'h1d,8'h1e,8'h1f,8'h20,8'h23,8'h24,8'h86,8'h87,8'h88,8'h89,8'hfd,8'hfe:is_result=1;
  default:is_result=0;
 endcase
end endfunction
always @(posedge clk or posedge rst)begin
 if(rst)begin native_left<=0;native_type<=0;last_screen_result<=0;screen_results<=0;native_text<=0;native_text_count<=0;native_ff<=0;screen_boot<=0;capture_text<=0;ri<=0;timeout_count<=0;crc<=16'hffff;wire_crc<=0;rsession<=0;rseq<=0;version<=0;target<=0;rop<=0;robj<=0;rlen<=0;rflags<=0;rval<=0;packet<=0;crc_errors<=0;framing_errors<=0;end
 else begin
  packet<=0;screen_boot<=0;
  if(re)begin native_left<=0;native_text<=0;ri<=0;timeout_count<=0;if(framing_errors!=65535)framing_errors<=framing_errors+1'b1;end
  else if(rv)begin
   timeout_count<=0;
   if(native_left!=0)begin
    native_left<=native_left-1'b1;
    if(native_left<=3 && rd!=8'hff)begin native_left<=0;if(framing_errors!=65535)framing_errors<=framing_errors+1'b1;end
    else if(native_left==1 && is_result(native_type))begin
     last_screen_result<=native_type;if(screen_results!=65535)screen_results<=screen_results+1'b1;
     if(native_type==8'h88)screen_boot<=1;
    end
   end else if(native_text)begin
    native_text_count<=native_text_count+1'b1;
    native_ff<=rd==8'hff ?native_ff+1'b1:2'd0;
    if((rd==8'hff && native_ff==2) || native_text_count==67)begin native_text<=0;native_ff<=0;end
   end else if(ri==0)begin
    if(rd==8'h55)begin ri<=1;capture_text<=state==0;end
    else begin
     native_type<=rd;
     if(is_result(rd))native_left<=3;
     else case(rd)
      8'h65:native_left<=6;8'h66:native_left<=4;
      8'h67,8'h68:native_left<=8;8'h71:native_left<=7;
      8'h70:begin native_text<=1;native_text_count<=0;native_ff<=0;end
      default:begin end
     endcase
    end
   end
   else if(ri==1)begin
    if(rd==8'haa)begin ri<=2;crc<=crc16(crc16(16'hffff,8'h55),8'haa);end
    else ri<=rd==8'h55 ?9'd1:9'd0;
   end else begin
    ri<=ri+1'b1;
    if(ri<12 || ri<payload_end)crc<=crc16(crc,rd);
    if(ri>=12 && ri<payload_end)begin
     if(rflags==0)case(ri)
      12:rval[7:0]<=rd;13:rval[15:8]<=rd;14:rval[23:16]<=rd;15:rval[31:24]<=rd;
      default:begin end
     endcase
     else if(text_frame && capture_text)text_ram[ri-9'd12]<=rd;
    end else if(ri==payload_end)wire_crc[7:0]<=rd;
    else if(ri==payload_end+9'd1)begin
     ri<=0;wire_crc[15:8]<=rd;
     if({rd,wire_crc[7:0]}==crc)packet<=1;
     else if(crc_errors!=65535)crc_errors<=crc_errors+1'b1;
    end
    case(ri)
     2:version<=rd;3:target<=rd;4:rsession[7:0]<=rd;5:rsession[15:8]<=rd;
     6:rseq[7:0]<=rd;7:rseq[15:8]<=rd;8:rop<=rd;9:robj<=rd;10:rlen<=rd;11:rflags<=rd;
     default:begin end
    endcase
   end
  end else if(ri!=0 || native_left!=0 || native_text)begin
   if(timeout_count==TIMEOUT_CYCLES-1)begin ri<=0;native_left<=0;native_text<=0;timeout_count<=0;if(framing_errors!=65535)framing_errors<=framing_errors+1'b1;end
   else timeout_count<=timeout_count+1'b1;
  end
 end
end
reg have_last;reg [15:0] last_seq,reply_seq,reply_session;
reg [7:0] last_op,last_object,last_code,reply_code,reply_object;
reg [31:0] last_value,last_result;reg reply_has_value;
wire [31:0] reply_value=reply_has_value?last_result:32'd0;
// The duplicate cache already holds the dispatched payload until the next
// accepted transaction. The mailbox captures it with command_valid; avoid a
// second resettable copy of the same 48 bits.
assign command_op=last_op;assign command_object=last_object;assign command_value=last_value;
reg [3:0] state;reg [1:0] part;reg [4:0] pos;reg [3:0] digit;
reg [5:0] bit_count;reg [31:0] magnitude;reg [39:0] bcd;
reg negative;reg [1:0] tail_count;reg [$clog2(GAP_CYCLES+1)-1:0] gap;
wire [31:0] format_value=part==0?reply_value:part==1?{reply_session,reply_object,reply_code}:{16'd0,reply_seq};
wire identical=have_last && rseq==last_seq && rop==last_op && robj==last_object && request_value==last_value;
// Ten nibble rotations share one add-three circuit. Conversion is still less
// than 8 us at 50 MHz, far below one UART character; no parallel BCD adders.
reg [3:0] nibble_count;
wire [3:0] adjusted=bcd[39:36]>=5?bcd[39:36]+4'd3:bcd[39:36];
function [7:0] prefix;input [1:0] p;input [4:0] at;
 begin
  prefix=8'h3d;
  case(at)
   0:prefix="h";1:prefix="r";
   2:prefix=p==0?"v":p==1?"m":"s";
   3:prefix=p==0?"a":"e";
   4:prefix=p==0?"l":p==1?"t":"q";
   5:prefix=p==1?"a":"=";
   default:prefix="=";
  endcase
 end
endfunction
always @(posedge clk or posedge rst)begin
 if(rst)begin
  command_valid<=0;
  busy_drops<=0;session_id<=0;have_last<=0;last_seq<=0;last_op<=0;last_object<=0;last_value<=0;last_result<=0;last_code<=0;
  reply_seq<=0;reply_session<=0;reply_code<=0;reply_object<=0;reply_has_value<=0;
  state<=0;part<=0;pos<=0;digit<=0;bit_count<=0;nibble_count<=0;magnitude<=0;bcd<=0;negative<=0;tail_count<=0;gap<=0;ts<=0;td<=0;
 end else begin
  command_valid<=0;ts<=0;
  if(packet && state!=0 && busy_drops!=65535)busy_drops<=busy_drops+1'b1;
  case(state)
   0:if(packet)begin
    reply_seq<=rseq;reply_session<=rsession;reply_object<=robj;reply_has_value<=0;reply_code<=0;part<=0;state<=2;
    if(version!=6 || target!=1 || (!text_frame && (rlen!=4 || rflags!=0)))reply_code<=11;
    else if(rop==0)begin
     if(rsession==0 || robj!=0 || rval!=32'h00020006)reply_code<=4;
     else if(rsession==session_id && identical)begin reply_has_value<=1;reply_code<=last_code;end
     else if(rsession==session_id)reply_code<=4;
     else begin
      session_id<=rsession;have_last<=1;last_seq<=rseq;last_op<=rop;last_object<=robj;last_value<=request_value;last_result<=32'h00020006;last_code<=0;reply_has_value<=1;
     end
    end else if(session_id==0 || rsession!=session_id)reply_code<=4;
    else if(identical)begin reply_has_value<=1;reply_code<=last_code;end
    else if(!have_last || rseq!=last_seq+16'd1)reply_code<=6;
    else begin
     last_seq<=rseq;last_op<=rop;last_object<=robj;last_value<=request_value;
     if(rop==1 && robj>=8'hf0 && robj<=8'hf3)begin
      reply_has_value<=1;
      last_result<=robj==8'hf0 ?{16'd0,crc_errors}:robj==8'hf1 ?{16'd0,framing_errors}:robj==8'hf2 ?{16'd0,busy_drops}:{8'd0,last_screen_result,screen_results};last_code<=0;
     end else begin command_valid<=1;state<=1;end
    end
   end
   1:if(command_done)begin reply_code<=command_code;reply_has_value<=1;last_code<=command_code;last_result<=command_result;state<=2;end
   2:begin bcd<=0;magnitude<=format_value[31]?(~format_value+32'd1):format_value;negative<=format_value[31];bit_count<=0;nibble_count<=0;state<=3;end
   3:begin bcd<={bcd[35:0],adjusted};
    if(nibble_count==9)begin nibble_count<=0;state<=9;end else nibble_count<=nibble_count+1'b1;
   end
   9:begin bcd<={bcd[38:0],magnitude[31]};magnitude<=magnitude<<1;
    if(bit_count==31)begin pos<=0;state<=4;end else begin bit_count<=bit_count+1'b1;state<=3;end
   end
   4:if(!tbusy && !ts)begin
    td<=prefix(part,pos);ts<=1;
    if(pos==(part==1?6:5))begin digit<=9;state<=5;end else pos<=pos+1'b1;
   end
   5:if(!tbusy && !ts)begin
    if(negative)begin td<="-";ts<=1;negative<=0;end
    else if(digit!=0 && bcd[39:36]==0)begin digit<=digit-1'b1;bcd<=bcd<<4;end
    else state<=6;
   end
   6:if(!tbusy && !ts)begin
    td<=8'd48+{4'd0,bcd[39:36]};ts<=1;bcd<=bcd<<4;
    if(digit==0)begin tail_count<=0;state<=7;end else digit<=digit-1'b1;
   end
   7:if(!tbusy && !ts)begin td<=8'hff;ts<=1;if(tail_count==2)begin gap<=0;state<=8;end else tail_count<=tail_count+1'b1;end
   8:if(!tbusy && !ts)begin
    if(gap==GAP_CYCLES-1)begin if(part==2)state<=0;else begin part<=part+1'b1;state<=2;end end
    else gap<=gap+1'b1;
   end
   default:state<=0;
  endcase
  if(screen_boot)begin session_id<=0;have_last<=0;end
 end
end
endmodule
