// One complete caption generation, for either local B or remote A. The caller
// routes the same ready/done transaction port. Cancel drains the current font
// and transaction, then restarts from BEGIN; sequential DATA is never replayed.
module bq_caption_builder #(
 parameter integer POLL_CYCLES=50000, parameter integer MAX_CYCLES=400000000
)(
 input clk,rst,start,cancel,input [15:0] epoch,input [5:0] count,
 output reg busy,done,output reg [7:0] error,
 output reg [4:0] char_address,input [15:0] character,
 output reg font_start,output reg [15:0] font_character,
 input font_busy,font_done,input [3:0] font_error,
 input word_valid,input [4:0] row_index,input [31:0] row_word,output reg word_ready,
 output reg request,input request_ready,output reg [2:0] operation,output reg [31:0] value,
 input response_done,input [7:0] response_code,input [31:0] response_value,
 output reg [15:0] applied_epoch
);
 localparam IDLE=0,SEND=1,WAIT=2,CHAR_WAIT=3,FONT_START=4,FONT_RUN=5,ROW_DROP=6,POLL=7;
 localparam AFTER_BEGIN=0,AFTER_ROW=1,AFTER_COMMIT=2,AFTER_STATUS=3;
 localparam integer PW=$clog2(POLL_CYCLES+1),AW=$clog2(MAX_CYCLES+1);
 reg [3:0] state;reg [1:0] after_request;reg inflight,aborting;reg [7:0] abort_error;
 reg [15:0] epoch_held;reg [5:0] count_held;reg [10:0] words;
 reg [31:0] crc,row_held;reg [4:0] expected_row;
 reg [PW-1:0] poll_age;reg [AW-1:0] age;
 function [31:0] crc_word;
  input [31:0] previous,data;reg [31:0] c;integer i;
  begin c=previous^data;for(i=0;i<32;i=i+1)c=c[0]?(c>>1)^32'hedb88320:c>>1;crc_word=c;end
 endfunction
 task issue;
  input [2:0] op;input [31:0] val;input [1:0] next;
  begin operation<=op;value<=val;after_request<=next;request<=1;state<=SEND;end
 endtask
 task finish;
  input [7:0] reason;
  begin busy<=0;done<=1;error<=reason;state<=IDLE;end
 endtask
 always @(posedge clk or posedge rst)begin
  if(rst)begin
   state<=IDLE;busy<=0;done<=0;error<=0;char_address<=0;font_start<=0;font_character<=0;
   word_ready<=0;request<=0;operation<=0;value<=0;inflight<=0;aborting<=0;abort_error<=0;
   epoch_held<=0;count_held<=0;words<=0;crc<=32'hffffffff;row_held<=0;expected_row<=0;
   after_request<=0;poll_age<=0;age<=0;applied_epoch<=0;
  end else begin
   done<=0;font_start<=0;word_ready<=0;
   if(request && request_ready)begin request<=0;inflight<=1;end
   if(inflight && response_done)inflight<=0;
   if(busy && age<MAX_CYCLES)age<=age+1'b1;
   if(busy && (cancel || age==MAX_CYCLES))begin aborting<=1;abort_error<=cancel?8'd10:8'd9;end
   if(busy && (aborting || cancel || age==MAX_CYCLES))begin
    // The reader may still own the SD sector. Consume and discard its remaining
    // rows, but never publish a partially written generation.
    word_ready<=1;
    if(!request && !inflight && !font_busy && !font_start)begin
     finish(aborting?abort_error:(cancel?8'd10:8'd9));aborting<=0;
    end
   end else case(state)
    IDLE:if(start)begin
     if(epoch==0 || count>32)begin done<=1;error<=2;end
     else begin
      busy<=1;error<=0;age<=0;aborting<=0;epoch_held<=epoch;count_held<=count;
      char_address<=0;expected_row<=0;words<=0;crc<=32'hffffffff;
      issue(0,{epoch,10'd0,count},AFTER_BEGIN);
     end
    end
    SEND:if(request_ready)state<=WAIT;
    WAIT:if(response_done)begin
     if(response_code!=0 && !(after_request==AFTER_COMMIT && response_code==1))begin
      // A rejected word must also drain a font read before another job starts.
      aborting<=1;abort_error<=response_code;
     end else case(after_request)
      AFTER_BEGIN:if(count_held==0)issue(2,0,AFTER_COMMIT);else state<=CHAR_WAIT;
      AFTER_ROW:begin
       if(response_value!={21'd0,words}+32'd1)begin aborting<=1;abort_error<=4;end
       else begin words<=words+1'b1;crc<=crc_word(crc,row_held);word_ready<=1;state<=ROW_DROP;end
      end
      AFTER_COMMIT:begin poll_age<=0;state<=POLL;end
      AFTER_STATUS:begin
       if(response_value[31:16]==epoch_held && !response_value[7])begin
        if(response_value[5:0]!=count_held)finish(4);
        else begin applied_epoch<=epoch_held;finish(0);end
       end else begin poll_age<=0;state<=POLL;end
      end
     endcase
    end
    CHAR_WAIT:state<=FONT_START;
    FONT_START:begin font_character<=character;font_start<=1;expected_row<=0;state<=FONT_RUN;end
    FONT_RUN:begin
     if(word_valid)begin
      if(row_index!=expected_row)begin aborting<=1;abort_error<=4;end
      else begin row_held<=row_word;issue(1,row_word,AFTER_ROW);end
     end else if(font_done)begin
      // SD error values overlap protocol BUSY/CANCEL. Keep font CRC/header
      // codes 12/13, but give card errors their own range so a bad card does
      // not look like an indefinitely retryable cache contention.
      if(font_error!=0)finish(font_error<12?{4'h1,font_error}:{4'd0,font_error});
      else if({1'b0,char_address}+6'd1==count_held)issue(2,~crc,AFTER_COMMIT);
      else begin char_address<=char_address+1'b1;state<=CHAR_WAIT;end
     end
    end
    ROW_DROP:if(!word_valid)begin expected_row<=expected_row+1'b1;state<=FONT_RUN;end
    POLL:if(poll_age==POLL_CYCLES-1)issue(3,0,AFTER_STATUS);else poll_age<=poll_age+1'b1;
    default:state<=IDLE;
   endcase
  end
 end
endmodule
