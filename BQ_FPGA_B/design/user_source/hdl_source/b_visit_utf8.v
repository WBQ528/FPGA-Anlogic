// ASCII URL prefix is constant; each selected POI byte is serialized by FPGA.
// This is a link payload, never a stored QR matrix or a precomputed route.
module b_visit_utf8(input [11:0] order,input [2:0] count,input [6:0] index,
 output reg [7:0] data,output [7:0] length);
localparam [6:0] PREFIX_LENGTH=7'd42;
assign length={1'b0,PREFIX_LENGTH}+{5'd0,count};
reg [1:0] slot;reg [2:0] poi;
always @*begin
 slot=index-PREFIX_LENGTH;poi=order[slot*3+:3];data=0;
 if(index<PREFIX_LENGTH)begin
  case(index)
   7'd0:data=8'h68;
   7'd1:data=8'h74;
   7'd2:data=8'h74;
   7'd3:data=8'h70;
   7'd4:data=8'h73;
   7'd5:data=8'h3a;
   7'd6:data=8'h2f;
   7'd7:data=8'h2f;
   7'd8:data=8'h77;
   7'd9:data=8'h62;
   7'd10:data=8'h71;
   7'd11:data=8'h35;
   7'd12:data=8'h32;
   7'd13:data=8'h38;
   7'd14:data=8'h2e;
   7'd15:data=8'h67;
   7'd16:data=8'h69;
   7'd17:data=8'h74;
   7'd18:data=8'h68;
   7'd19:data=8'h75;
   7'd20:data=8'h62;
   7'd21:data=8'h2e;
   7'd22:data=8'h69;
   7'd23:data=8'h6f;
   7'd24:data=8'h2f;
   7'd25:data=8'h46;
   7'd26:data=8'h50;
   7'd27:data=8'h47;
   7'd28:data=8'h41;
   7'd29:data=8'h5f;
   7'd30:data=8'h42;
   7'd31:data=8'h51;
   7'd32:data=8'h5f;
   7'd33:data=8'h67;
   7'd34:data=8'h75;
   7'd35:data=8'h69;
   7'd36:data=8'h64;
   7'd37:data=8'h65;
   7'd38:data=8'h2f;
   7'd39:data=8'h3f;
   7'd40:data=8'h72;
   7'd41:data=8'h3d;
   default:data=0;
  endcase
 end else if(index<length)data=8'h30+{5'd0,poi};
end
endmodule
