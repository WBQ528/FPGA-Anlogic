// Bounded QR Model 2 encoder: version 5, M, UTF-8 ECI26 + byte segment.
// Maximum 82 payload bytes. All payload coding, two GF(256) RS(67,43)
// blocks, interleaving, placement, eight-mask scoring and format BCH run here.
// Input text is a stable snapshot while busy; output is a completed matrix
// stream for an inactive display bank. No precomputed QR bitmap is consumed.
module b_qr_encoder(input clk,rst,start,input [7:0] payload_length,
 output [6:0] payload_index,input [7:0] payload_byte,
 output busy,output reg done,output reg [1:0] error,
 output reg module_write,output reg [5:0] module_x,module_y,output reg module_bit,
 output reg [2:0] chosen_mask);
localparam IDLE=0,ENCODE=1,RS_CLEAR=2,RS_WAIT=3,RS_FACTOR=4,RS_STEP=5,RS_OUT=6,
 CLEAR=7,PLACE_ADDR=8,PLACE_WRITE=9,SCORE_ADDR=10,SCORE_WAIT=11,SCORE_USE=12,
 BALANCE=13,MASK_DONE=14,OUTPUT_ADDR=15,OUTPUT_WAIT=16,OUTPUT_USE=17,
 SCORE_BIT=18,SCORE_PENALTY=19;
reg [4:0] state;reg [7:0] length;reg [6:0] n;
// One BRAM: final codewords 0..133, immutable input bytes 134..219.
reg [7:0] codewords[0:255];reg [191:0] ecc;
reg [7:0] ram_q,factor;wire [7:0] data_q=ram_q,code_q=ram_q;reg block_id;reg [5:0] data_i;reg [4:0] e_i;
reg matrix[0:1368];reg matrix_q;reg [10:0] init_address,bit_index;
reg [5:0] right,row;reg side,up;
reg [5:0] read_x,read_y;wire [10:0] read_address=({5'd0,read_y}<<5)+({5'd0,read_y}<<2)+{5'd0,read_y}+{5'd0,read_x};
reg [2:0] mask,best_mask;reg [15:0] score,best_score;
reg [5:0] scan_line,scan_pos;reg vertical;
reg [10:0] window;reg last_bit;reg [5:0] run_length;
reg [36:0] prior_row;reg above_left;reg [10:0] dark_count;reg [14:0] imbalance;
assign payload_index=n-7'd3;
assign busy=state!=IDLE;
function [7:0] gf_mul;input [7:0] a,b;reg [7:0] x,z;integer i;
 begin x=a;z=0;for(i=0;i<8;i=i+1)begin if(b[i])z=z^x;x=(x<<1)^(x[7] ? 8'h1d:8'd0);end gf_mul=z;end
endfunction
// Coefficients of product(i=0..23)(x + alpha^i), alpha=2, polynomial 0x11D.
// These are standard polynomial constants, not data-dependent ECC results.
function [7:0] generator;input [4:0] i;begin case(i)
 0:generator=122;1:generator=118;2:generator=169;3:generator=70;
 4:generator=178;5:generator=237;6:generator=216;7:generator=102;
 8:generator=115;9:generator=150;10:generator=229;11:generator=73;
 12:generator=130;13:generator=72;14:generator=61;15:generator=43;
 16:generator=206;17:generator=1;18:generator=237;19:generator=247;
 20:generator=127;21:generator=217;22:generator=144;default:generator=117;
endcase end endfunction
function [14:0] format_bits;input [2:0] m;reg [14:0] rem;integer i;
 begin rem={12'd0,m};for(i=0;i<10;i=i+1)rem=(rem<<1)^(rem[9] ? 15'h537:15'd0);
 format_bits=({2'd0,m,10'd0}|rem)^15'h5412;end
endfunction
// {reserved,value}; priority matches finder/alignment/format construction.
function [1:0] function_symbol;input [5:0] x,y;input [2:0] m;
 reg [5:0] fx,fy;reg [3:0] fi;reg format_valid;reg [14:0] fmt;reg [1:0] result;
 begin
  result=0;fmt=format_bits(m);fi=0;format_valid=1;
  if(x==6)result={1'b1,!y[0]};
  if(y==6)result={1'b1,!x[0]};
  if((x<=7 && y<=7) || (x>=29 && y<=7) || (x<=7 && y>=29))begin
   fx=x>=29 ? x-6'd30:x;fy=y>=29 ? y-6'd30:y;
   result={1'b1,fx<=6 && fy<=6 && (fx==0 || fx==6 || fy==0 || fy==6 ||
          (fx>=2 && fx<=4 && fy>=2 && fy<=4))};
  end
  if(x>=28 && x<=32 && y>=28 && y<=32)begin
   result={1'b1,x==28 || x==32 || y==28 || y==32 || (x==30 && y==30)};
  end
  if(x==8 && y<=5)fi=y;
  else if(x==8 && y==7)fi=6;
  else if(x==8 && y==8)fi=7;
  else if(x==7 && y==8)fi=8;
  else if(y==8 && x<=5)fi=14-x;
  else if(y==8 && x>=29)fi=36-x;
  else if(x==8 && y>=30)fi=y-22;
  else format_valid=0;
  if(format_valid)result={1'b1,fmt[fi]};
  if(x==8 && y==29)result=2'b11;
  function_symbol=result;
 end
endfunction
function mask_value;input [2:0] m;input [5:0] x,y;reg [1:0] xr,yr,pr;reg parity;begin
 xr=x%3;yr=y%3;pr=(xr*yr)%3;parity=x[0]&y[0];
 case(m)
  0:mask_value=!(x[0]^y[0]);1:mask_value=!y[0];2:mask_value=xr==0;
  3:mask_value=(xr+{1'b0,yr})%3==0;
  4:mask_value=((x/3)+(y/2))%2==0;
  5:mask_value=!parity && pr==0;6:mask_value=!(parity^pr[0]);
  default:mask_value=!(x[0]^y[0]^pr[0]);
 endcase
end endfunction
wire [5:0] place_x=right-{5'd0,side};
wire [10:0] place_address=({5'd0,row}<<5)+({5'd0,row}<<2)+{5'd0,row}+{5'd0,place_x};
wire [1:0] place_function=function_symbol(place_x,row,3'd0);
wire output_stage=state==OUTPUT_ADDR || state==OUTPUT_WAIT || state==OUTPUT_USE;
wire [1:0] current_function=function_symbol(read_x,read_y,output_stage ? best_mask:mask);
wire current_bit=current_function[1] ? current_function[0]:(matrix_q^mask_value(output_stage ? best_mask:mask,read_x,read_y));
reg scored_bit;reg [7:0] penalty_q;
wire [10:0] next_window={window[9:0],scored_bit};
reg [7:0] penalty;
always @*begin
 penalty=0;
 if(scan_pos<37)begin
  if(scan_pos!=0 && scored_bit==last_bit)begin
   if(run_length==4)penalty=penalty+8'd3;else if(run_length>=5)penalty=penalty+8'd1;
  end
  if(!vertical && scan_line!=0 && scan_pos!=0 && scored_bit==last_bit && scored_bit==prior_row[0] && scored_bit==above_left)penalty=penalty+8'd3;
 end
 // Include the four-module quiet zone at either side in finder-like scoring.
 if(scan_pos>=6 && (next_window==11'b00001011101 || next_window==11'b10111010000))penalty=penalty+8'd40;
end
// One explicit write port lets the synthesizer use a 256 x 8 embedded RAM.
// Several syntactic array writes incorrectly infer multi-port flip-flop RAM.
reg cw_write;reg [7:0] cw_address,cw_data;
wire matrix_write=(state==CLEAR) || (state==PLACE_WRITE && !place_function[1]);
wire [10:0] matrix_write_address=state==CLEAR ? init_address:place_address;
wire matrix_write_data=state!=CLEAR && bit_index<1072 && code_q[7-bit_index[2:0]];
always @*begin
 cw_write=0;cw_address=0;cw_data=0;
 if(state==ENCODE)begin
  cw_write=1;cw_address=8'd134+{1'b0,n};
  if(n==0)cw_data=8'h71;
  else if(n==1)cw_data=8'ha4;
  else if(n==2)cw_data=length;
  else if(n<length+8'd3)cw_data=payload_byte;
  else if(n==length+8'd3)cw_data=0;
  else cw_data=((n-length-8'd4)&1) ? 8'h11:8'hec;
 end
 else if(state==RS_FACTOR)begin cw_write=1;cw_address={data_i,1'b0}+block_id;cw_data=data_q;end
 else if(state==RS_OUT)begin cw_write=1;cw_address=8'd86+{e_i,1'b0}+block_id;cw_data=ecc[191:184];end
end
reg cw_we_q;reg [7:0] cw_addr_q,cw_data_q;
always @(posedge clk)begin
 cw_we_q<=!rst && cw_write;cw_addr_q<=cw_address;cw_data_q<=cw_data;
 ram_q<=codewords[(state==RS_WAIT || state==RS_FACTOR) ? 8'd134+(block_id ? 8'd43:8'd0)+{2'd0,data_i}:bit_index[10:3]];
 if(cw_we_q)codewords[cw_addr_q]<=cw_data_q;
 matrix_q<=matrix[read_address];
 if(matrix_write)matrix[matrix_write_address]<=matrix_write_data;
end
always @(posedge clk or posedge rst)begin
 if(rst)begin
  state<=IDLE;length<=0;n<=0;done<=0;error<=0;block_id<=0;data_i<=0;e_i<=0;factor<=0;
  init_address<=0;bit_index<=0;right<=36;row<=36;side<=0;up<=1;read_x<=0;read_y<=0;
  mask<=0;best_mask<=0;score<=0;best_score<=65535;scan_line<=0;scan_pos<=0;vertical<=0;window<=0;last_bit<=0;run_length<=0;prior_row<=0;above_left<=0;dark_count<=0;imbalance<=0;
  module_write<=0;module_x<=0;module_y<=0;module_bit<=0;chosen_mask<=0;scored_bit<=0;penalty_q<=0;
 end else begin
  done<=0;module_write<=0;
  case(state)
   IDLE:if(start)begin
    error<=0;
    if(payload_length>82)begin error<=1;done<=1;end
    else begin length<=payload_length;n<=0;state<=ENCODE;end
   end
   ENCODE:if(n==85)begin block_id<=0;data_i<=0;e_i<=0;state<=RS_CLEAR;end else n<=n+1'b1;
   RS_CLEAR:begin ecc<=0;e_i<=0;state<=RS_WAIT;end
   RS_WAIT:state<=RS_FACTOR;
   RS_FACTOR:begin factor<=data_q^ecc[191:184];e_i<=0;state<=RS_STEP;end
   RS_STEP:begin
    ecc<={ecc[183:0],(e_i==23 ? 8'd0:ecc[183:176])^gf_mul(factor,generator(e_i))};
    if(e_i==23)begin e_i<=0;
     if(data_i==42)state<=RS_OUT;else begin data_i<=data_i+1'b1;state<=RS_WAIT;end
    end else e_i<=e_i+1'b1;
   end
   RS_OUT:begin ecc<={ecc[183:0],8'd0};if(e_i==23)begin
    e_i<=0;if(!block_id)begin block_id<=1;data_i<=0;state<=RS_CLEAR;end
    else begin init_address<=0;state<=CLEAR;end
   end else e_i<=e_i+1'b1;end
   CLEAR:if(init_address==1368)begin right<=36;row<=36;side<=0;up<=1;bit_index<=0;state<=PLACE_ADDR;end else init_address<=init_address+1'b1;
   PLACE_ADDR:state<=PLACE_WRITE;
   PLACE_WRITE:begin
    if(!place_function[1])bit_index<=bit_index+1'b1;
    state<=PLACE_ADDR;
    if(!side)side<=1;
    else begin
     side<=0;
     if((up && row==0) || (!up && row==36))begin
      up<=~up;right<=right==8 ? 6'd5:right-6'd2;
      if(right==1)begin
       mask<=0;best_mask<=0;best_score<=65535;score<=0;dark_count<=0;
       scan_line<=0;scan_pos<=0;vertical<=0;window<=0;run_length<=0;prior_row<=0;above_left<=0;
       state<=SCORE_ADDR;
      end
     end else row<=up ? row-1'b1:row+1'b1;
    end
   end
   SCORE_ADDR:begin
    read_x<=vertical ? scan_line:scan_pos<37 ? scan_pos:6'd0;
    read_y<=vertical ? (scan_pos<37 ? scan_pos:6'd0):scan_line;state<=SCORE_WAIT;
   end
   SCORE_WAIT:state<=SCORE_BIT;
   SCORE_BIT:begin scored_bit<=scan_pos<37 ? current_bit:1'b0;state<=SCORE_PENALTY;end
   SCORE_PENALTY:begin penalty_q<=penalty;state<=SCORE_USE;end
   SCORE_USE:begin
    score<=score+penalty_q;window<=next_window;
    if(scan_pos<37)begin
     last_bit<=scored_bit;run_length<=scan_pos!=0 && scored_bit==last_bit ? run_length+1'b1:6'd1;
     // A 37-bit rolling line store keeps the previous row's current column
     // at bit zero. After 37 shifts it contains the new row in the same order.
     // This removes a 37-way variable read/write decoder without changing N2.
     if(!vertical)begin dark_count<=dark_count+scored_bit;above_left<=prior_row[0];prior_row<={scored_bit,prior_row[36:1]};end
    end
    state<=SCORE_ADDR;
    if(scan_pos==40)begin
     scan_pos<=0;window<=0;run_length<=0;above_left<=0;
     if(scan_line==36)begin
      scan_line<=0;
      if(!vertical)vertical<=1;
      else begin
       imbalance<=dark_count*15'd20>15'd13690 ? dark_count*15'd20-15'd13690:15'd13690-dark_count*15'd20;
       state<=BALANCE;
      end
     end else scan_line<=scan_line+1'b1;
    end else scan_pos<=scan_pos+1'b1;
   end
   BALANCE:if(imbalance>=1369)begin imbalance<=imbalance-15'd1369;score<=score+16'd10;end else state<=MASK_DONE;
   MASK_DONE:begin
    if(score<best_score)begin best_score<=score;best_mask<=mask;end
    if(mask==7)begin read_x<=0;read_y<=0;state<=OUTPUT_ADDR;end
    else begin mask<=mask+1'b1;score<=0;dark_count<=0;scan_line<=0;scan_pos<=0;vertical<=0;window<=0;run_length<=0;prior_row<=0;above_left<=0;state<=SCORE_ADDR;end
   end
   OUTPUT_ADDR:state<=OUTPUT_WAIT;
   OUTPUT_WAIT:state<=OUTPUT_USE;
   OUTPUT_USE:begin
    module_write<=1;module_x<=read_x;module_y<=read_y;module_bit<=current_bit;chosen_mask<=best_mask;
    if(read_x==36)begin read_x<=0;
     if(read_y==36)begin done<=1;state<=IDLE;end
     else begin read_y<=read_y+1'b1;state<=OUTPUT_ADDR;end
    end else begin read_x<=read_x+1'b1;state<=OUTPUT_ADDR;end
   end
   default:begin error<=2;done<=1;state<=IDLE;end
  endcase
 end
end
endmodule
