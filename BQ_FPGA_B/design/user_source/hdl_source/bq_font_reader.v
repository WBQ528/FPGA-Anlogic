// Read one ordinary GB2312 glyph from a generic font file. Records are 256
// bytes: magic/code, CRC32, 32 bitmap rows, padding. Two records per sector.
// The sector port is an arbitrated, bounded read service, not a private TF bus.
module bq_font_reader #(parameter [31:0] FONT_BASE_LBA=0)(
 input clk,rst,start,input [15:0] character,
 output reg busy,done,output reg [3:0] error,
 output reg sector_request,output reg [31:0] sector_lba,
 input sector_done,input [3:0] sector_error,
 output reg [8:0] byte_address,input [7:0] byte_data,
 output reg word_valid,output reg [4:0] row_index,
 output reg [31:0] row_word,input word_ready
);
 reg [3:0] state;reg [15:0] code_held;reg [1:0] byte_index;
 reg [5:0] record_word;reg [31:0] assembly,expected_crc,crc;
 function [31:0] crc_word;
  input [31:0] previous,data;reg [31:0] c;integer j;
  begin c=previous^data;for(j=0;j<32;j=j+1)c=c[0]?(c>>1)^32'hedb88320:c>>1;crc_word=c;end
 endfunction
 always @(posedge clk or posedge rst)begin
  if(rst)begin
   state<=0;busy<=0;done<=0;error<=0;sector_request<=0;sector_lba<=0;byte_address<=0;
   word_valid<=0;row_index<=0;row_word<=0;code_held<=0;byte_index<=0;record_word<=0;assembly<=0;expected_crc<=0;crc<=32'hffffffff;
  end else begin
   done<=0;sector_request<=0;
   case(state)
    0:if(start)begin
     busy<=1;error<=0;code_held<=character;sector_lba<=FONT_BASE_LBA+32'd1+{17'd0,character[15:1]};
     sector_request<=1;word_valid<=0;byte_index<=0;record_word<=0;crc<=32'hffffffff;state<=1;
    end
    1:if(sector_done)begin
     if(sector_error!=0)begin error<=sector_error;state<=7;end
     else begin byte_address<={code_held[0],8'd0};state<=2;end
    end
    2:state<=3;
    3:begin
     assembly<={byte_data,assembly[31:8]};byte_address<=byte_address+1'b1;
     if(byte_index==3)begin byte_index<=0;state<=4;end
     else begin byte_index<=byte_index+1'b1;state<=2;end
    end
    4:begin
     if(record_word==0)begin
      if(assembly!={16'hb708,code_held})begin error<=4'hd;state<=7;end
      else begin record_word<=1;state<=2;end
     end else if(record_word==1)begin expected_crc<=assembly;record_word<=2;state<=2;end
     else begin row_word<=assembly;row_index<=record_word[4:0]-5'd2;word_valid<=1;state<=5;end
    end
    5:if(word_ready)begin
     word_valid<=0;crc<=crc_word(crc,row_word);
     if(record_word==33)state<=6;
     else begin record_word<=record_word+1'b1;state<=2;end
    end
    6:begin if(~crc!=expected_crc)error<=4'hc;state<=7;end
    7:begin busy<=0;done<=1;state<=0;end
    default:state<=0;
   endcase
  end
 end
endmodule
