// Two RGB888 input pixels -> one RGB565 pair. Reset on each frame handshake.
// Input must obey ready. Frame dimensions are even, so no partial last pair.
module rgb565_pack(input clk,rst,frame_reset,input valid,input [23:0] rgb,
 input ready,output input_ready,output out_valid,output [31:0] data);
reg half;reg [15:0] first;
wire [15:0] color={rgb[23:19],rgb[15:10],rgb[7:3]};
assign input_ready=!half || ready;
assign out_valid=valid && half && ready && !frame_reset;
assign data={color,first};
always @(posedge clk or posedge rst)begin
 if(rst)begin half<=0;first<=0;end
 else if(frame_reset)half<=0;
 else if(valid && input_ready)begin first<=color;half<=~half;end
end
endmodule
