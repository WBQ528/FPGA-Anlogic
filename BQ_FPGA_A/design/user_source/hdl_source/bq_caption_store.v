// runtime glyph cache. No caption image or effect frame is stored on TF.
// 32 characters x 32 rows x 32 bits x two banks = 8 KiB, no DSP.
// One writer clock; one synchronous video read port. Inactive bank is immutable
// from COMMIT until the video domain acknowledges at a frame boundary.
module bq_caption_store(
 input clk,rst,input valid,input [1:0] operation,input [31:0] value,
 output reg done,output reg [7:0] code,output reg [31:0] result,
 input video_clk,video_rst,frame_start,input [9:0] row_address,
 output reg [31:0] row_bits,output reg [5:0] visible_count,
 output reg [15:0] visible_epoch,
 output reg [15:0] applied_epoch,output reg [5:0] applied_count,
 output reg [15:0] display_serial
);
 reg [31:0] glyphs[0:2047];
 reg staging,write_bank,committed_bank;
 reg [5:0] count_held;reg [15:0] epoch_held,commit_epoch;
 reg [10:0] words;reg [31:0] crc;
 reg request,acknowledge,video_bank,seen,applied_seen;
 (* ASYNC_REG="TRUE" *) reg [1:0] ack_sync,req_sync;
 wire pending=request!=ack_sync[1];
 wire [10:0] expected_words={count_held,5'd0};
 function [31:0] crc_word;
  input [31:0] previous,data;reg [31:0] c;integer i;
  begin c=previous^data;for(i=0;i<32;i=i+1)c=c[0]?(c>>1)^32'hedb88320:c>>1;crc_word=c;end
 endfunction
 // Memory has no array reset; valid count/epoch gate every read after reset.
 always @(posedge clk)begin
  if(!rst && valid && operation==1 && staging && !pending && words<expected_words)
   glyphs[{write_bank,words[9:0]}]<=value;
 end
 always @(posedge video_clk)row_bits<=glyphs[{video_bank,row_address}];
 always @(posedge clk or posedge rst)begin
  if(rst)begin
   staging<=0;write_bank<=1;committed_bank<=0;count_held<=0;epoch_held<=0;applied_epoch<=0;applied_count<=0;commit_epoch<=0;applied_seen<=0;
   words<=0;crc<=32'hffffffff;request<=0;ack_sync<=0;done<=0;code<=0;result<=0;
  end else begin
   ack_sync<={ack_sync[0],acknowledge};done<=0;
   if(ack_sync[1]!=applied_seen)begin applied_epoch<=commit_epoch;applied_count<=count_held;applied_seen<=ack_sync[1];end
   if(valid)begin
    done<=1;code<=0;result<=0;
    case(operation)
     0:begin
      if(pending)code<=8;
      else if(value[15:6]!=0 || value[5:0]>32 || value[31:16]==0)code<=2;
      else begin
       staging<=1;write_bank<=!committed_bank;count_held<=value[5:0];epoch_held<=value[31:16];
       words<=0;crc<=32'hffffffff;result<=value;
      end
     end
     1:begin
      if(!staging || pending || words>=expected_words)code<=8;
      else begin words<=words+1'b1;crc<=crc_word(crc,value);result<={21'd0,words}+1'b1;end
     end
     2:begin
      if(!staging || pending || words!=expected_words)code<=8;
      else if(value!=~crc)begin code<=2;staging<=0;end
      else begin
       request<=~request;committed_bank<=write_bank;commit_epoch<=epoch_held;staging<=0;
       code<=1;result<={epoch_held,10'd0,count_held};
      end
     end
     3:result<={applied_epoch,8'd0,pending,staging,count_held};
    endcase
   end
  end
 end
 always @(posedge video_clk or posedge video_rst)begin
  if(video_rst)begin req_sync<=0;seen<=0;acknowledge<=0;video_bank<=0;visible_count<=0;visible_epoch<=0;display_serial<=0;end
  else begin
   req_sync<={req_sync[0],request};
   if(frame_start && req_sync[1]!=seen)begin
    video_bank<=committed_bank;visible_count<=count_held;visible_epoch<=epoch_held;
    display_serial<=display_serial+1'b1;
    seen<=req_sync[1];acknowledge<=req_sync[1];
   end
  end
 end
endmodule
