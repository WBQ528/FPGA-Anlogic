// Small classroom/demo status strip. No pipeline latency; raster coordinates
// refer to the input RGB/DE. Outside the top 32 rows, pixels pass unchanged.
module demo_status_overlay(
 input clk,rst,vs,de,input [23:0] rgb,
 input movie_mode,input [15:0] movie_frame,movie_stalls,
 input movie_paused,movie_muted,movie_ended,input [3:0] movie_error,
 input image_valid,input [1:0] image_id,input [9:0] status,
 output reg [23:0] out_rgb
);
reg [9:0] x;
reg [8:0] y;
reg de_d;
wire [9:0] local_x=x-10'd8;
wire [8:0] local_y=y-9'd8;
wire [5:0] char_index=local_x[9:4];
wire [2:0] col=local_x[3:1];
wire [2:0] row=local_y[3:1];
reg [7:0] character;
reg [34:0] glyph_bits;
reg [5:0] bit_index;
wire error_present=movie_mode ? movie_error!=0 : status[6:3]>=4'hb;
always @(posedge clk or posedge rst)begin
 if(rst)begin x<=0;y<=0;de_d<=0;end
 else begin
  de_d<=de;
  if(!vs)begin x<=0;y<=0;end
  else if(de)begin if(x<639)x<=x+1'b1;end
  else begin x<=0;if(de_d)y<=y+1'b1;end
 end
end
function [34:0] glyph;
 input [7:0] c;
 begin case(c)
 "V":glyph=35'b10001100011000110001100010101000100;
 "F":glyph=35'b11111100001000011110100001000010000;
 "I":glyph=35'b11111001000010000100001000010011111;
 "M":glyph=35'b10001110111010110101100011000110001;
 "G":glyph=35'b01110100011000010111100011000101110;
 "A":glyph=35'b01110100011000111111100011000110001;
 "U":glyph=35'b10001100011000110001100011000101110;
 "T":glyph=35'b11111001000010000100001000010000100;
 "O":glyph=35'b01110100011000110001100011000101110;
 "N":glyph=35'b10001110011010110011100011000110001;
 "H":glyph=35'b10001100011000111111100011000110001;
 "Z":glyph=35'b11111000010001000100010001000011111;
 "S":glyph=35'b01111100001000001110000010000111110;
 "P":glyph=35'b11110100011000111110100001000010000;
 "E":glyph=35'b11111100001000011110100001000011111;
 "B":glyph=35'b11110100011000111110100011000111110;
 "C":glyph=35'b01111100001000010000100001000001111;
 "D":glyph=35'b11110100011000110001100011000111110;
 "0":glyph=35'b01110100011001110101110011000101110;
 "1":glyph=35'b00100011000010000100001000010001110;
 "2":glyph=35'b01110100010000100010001000100011111;
 "3":glyph=35'b11110000010000101110000010000111110;
 "4":glyph=35'b00010001100101010010111110001000010;
 "5":glyph=35'b11111100001000011110000010000111110;
 "6":glyph=35'b01110100001000011110100011000101110;
 "7":glyph=35'b11111000010001000100010000100001000;
 "8":glyph=35'b01110100011000101110100011000101110;
 "9":glyph=35'b01110100011000101111000010000101110;
 default:glyph=0;
 endcase end
endfunction
function [7:0] hexchar;
 input [3:0] digit;
 begin hexchar=digit<10 ? 8'd48+{4'd0,digit} : 8'd55+{4'd0,digit};end
endfunction
always @*begin
 character=" ";
 case(char_index)
  0:character="I";1:character="M";2:character="G";
  3:character=image_valid ? (8'd49+{6'd0,image_id}) : "0";
  5:character=image_id>=2 ? "1" : "0";
  6:character=image_id==1 ? "7" : image_id==2 ? "0" : "5";
  7:character=image_id==1 ? "5" : "0";
  8:character="0";9:character="H";10:character="Z";
  13:character=status[9] ? "A" : "M";
  14:character=status[9] ? "U" : "A";
  15:character=status[9] ? "T" : "N";
  16:character=status[9] ? "O" : " ";
  18:character=status[8:7]==0 ? "1" : status[8:7]==1 ? "3" : "5";
  19:character="S";21:character="P";22:character=8'd48+{5'd0,status[2:0]};
  24:character="E";
  25:character=error_present ? (8'd55+{4'd0,status[6:3]}) : "0";
  default:;
 endcase
 if(movie_mode)begin
  character=" ";
  case(char_index)
   0:character="V";1:character="I";2:character="D";
   4:character=hexchar(movie_frame[15:12]);5:character=hexchar(movie_frame[11:8]);
   6:character=hexchar(movie_frame[7:4]);7:character=hexchar(movie_frame[3:0]);
   9:character="1";10:character="5";11:character="F";12:character="P";13:character="S";
   15:character="P";16:character=movie_paused ? "1":"0";
   18:character="M";19:character=movie_muted ? "1":"0";
   21:character="U";22:character=hexchar(movie_stalls[15:12]);23:character=hexchar(movie_stalls[11:8]);
   24:character=hexchar(movie_stalls[7:4]);25:character=hexchar(movie_stalls[3:0]);
   27:character="E";28:character=hexchar(movie_error);
   30:character=movie_ended ? "D":" ";
   default:;
  endcase
 end
 glyph_bits=glyph(character);
 bit_index=6'd34-({3'd0,row}*6'd5+{3'd0,col});
 out_rgb=rgb;
 if(de && y<32)begin
  out_rgb=error_present ? 24'h481820 : 24'h102838;
  if(y==31)out_rgb=24'h30c0c0;
  else if(x>=8 && y>=8 && y<22 && col<5 && char_index<32 && glyph_bits[bit_index])
   out_rgb=24'he8f4ff;
 end
end
endmodule

