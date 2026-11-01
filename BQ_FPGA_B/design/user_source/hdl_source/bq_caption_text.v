// Validate the bounded HMI GB2312 string before starting any media work.
// ASCII 0x20..0x7e and GB2312 lead a1..f7/trail a1..fe; actual glyph presence
// is checked by the font loader. No partial string is committed on errors.
module bq_caption_text(
 input clk,rst,start,input [6:0] byte_length,
 output reg [5:0] text_address,input [7:0] text_data,
 output reg busy,done,output reg [7:0] code,
 output reg [5:0] char_count,
 input [4:0] char_address,output reg [15:0] char_code
);
 reg [15:0] characters[0:31];
 reg [2:0] state;reg [6:0] length_held,index;
 reg lead;reg [7:0] first;
 always @(posedge clk)char_code<=characters[char_address];
 always @(posedge clk or posedge rst)begin
  if(rst)begin state<=0;busy<=0;done<=0;code<=0;text_address<=0;char_count<=0;length_held<=0;index<=0;lead<=0;first<=0;end
  else begin
   done<=0;
   case(state)
    0:if(start)begin
     busy<=1;code<=0;char_count<=0;lead<=0;first<=0;index<=0;text_address<=0;length_held<=byte_length;
     if(byte_length>64)begin code<=2;state<=4;end
     else if(byte_length==0)state<=4;
     else state<=1;
    end
    1:state<=2;
    2:begin
     if(lead)begin
      if(text_data<8'ha1 || text_data>8'hfe)begin code<=2;state<=4;end
      else begin
       characters[char_count[4:0]]<={first,text_data};char_count<=char_count+1'b1;lead<=0;state<=3;
      end
     end else if(char_count==32)begin code<=2;state<=4;end
     else if(text_data>=8'h20 && text_data<=8'h7e)begin
      characters[char_count[4:0]]<={8'd0,text_data};char_count<=char_count+1'b1;state<=3;
     end else if(text_data>=8'ha1 && text_data<=8'hf7)begin first<=text_data;lead<=1;state<=3;end
     else begin code<=2;state<=4;end
    end
    3:begin
     if(index+1'b1==length_held)begin if(lead)code<=2;state<=4;end
     else begin index<=index+1'b1;text_address<=text_address+1'b1;state<=1;end
    end
    4:begin done<=1;busy<=0;state<=0;end
    default:state<=0;
   endcase
  end
 end
endmodule
