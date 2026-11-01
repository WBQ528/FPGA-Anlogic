// Shared 0..100% volume, 10% steps; gain ramps at the audio sample rate.
// Preserve signed PCM and never exceed unity. Paused/muted data still clocks.
module audio_volume(input clk,rst,in_valid,input [23:0] in_left,in_right,
 input [3:0] volume,input paused,output reg out_valid,output reg [23:0] out_left,out_right);
reg [8:0] gain;reg [8:0] target;
always @*case(volume)
 0:target=0;1:target=26;2:target=51;3:target=77;4:target=102;5:target=128;
 6:target=154;7:target=179;8:target=205;9:target=230;default:target=256;
endcase
wire signed [33:0] left_scaled=$signed(in_left)*$signed({1'b0,gain});
wire signed [33:0] right_scaled=$signed(in_right)*$signed({1'b0,gain});
always @(posedge clk or posedge rst)begin
 if(rst)begin gain<=0;out_valid<=0;out_left<=0;out_right<=0;end
 else begin out_valid<=in_valid;if(in_valid)begin
  if(gain<target)gain<=gain+1'b1;else if(gain>target)gain<=gain-1'b1;
  out_left<=paused?24'd0:left_scaled[31:8];out_right<=paused?24'd0:right_scaled[31:8];
 end end
end
endmodule
