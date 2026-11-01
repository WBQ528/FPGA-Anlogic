// R5: 74.166667 MHz pixel-domain PCM, 48 kHz average, signed 24-bit stereo.
// Rational sample enable alternates 1545/1546 clocks. N=6144, CTS=74167.
// Continuous phase and 256-sample gain ramp avoid start/stop discontinuities.
module audio_demo_pcm(
 input clk, rst, image_valid, input [1:0] image_id,
 output reg audio_valid, output reg [23:0] audio_left, audio_right,
 output reg acr_valid, output [19:0] acr_n, acr_cts
);
reg [26:0] sample_acc;
reg [31:0] phase;
reg [5:0] acr_count;
reg [7:0] gain;
reg [31:0] phase_step;
wire signed [15:0] wave = sine(phase[31:26]);
wire signed [24:0] scaled = wave * $signed({1'b0,gain});
assign acr_n=20'd6144;
assign acr_cts=20'd74167;
always @* case(image_id)
  0: phase_step=32'd44739243; // 500 Hz
  1: phase_step=32'd67108864; // 750 Hz
  2: phase_step=32'd89478485; // 1000 Hz
  default: phase_step=32'd134217728; // 1500 Hz
endcase
function signed [15:0] sine;
 input [5:0] position;
 begin case(position)
            6'd0: sine = 16'sd0;
            6'd1: sine = 16'sd401;
            6'd2: sine = 16'sd799;
            6'd3: sine = 16'sd1189;
            6'd4: sine = 16'sd1567;
            6'd5: sine = 16'sd1930;
            6'd6: sine = 16'sd2275;
            6'd7: sine = 16'sd2598;
            6'd8: sine = 16'sd2896;
            6'd9: sine = 16'sd3165;
            6'd10: sine = 16'sd3405;
            6'd11: sine = 16'sd3611;
            6'd12: sine = 16'sd3783;
            6'd13: sine = 16'sd3919;
            6'd14: sine = 16'sd4016;
            6'd15: sine = 16'sd4075;
            6'd16: sine = 16'sd4095;
            6'd17: sine = 16'sd4075;
            6'd18: sine = 16'sd4016;
            6'd19: sine = 16'sd3919;
            6'd20: sine = 16'sd3783;
            6'd21: sine = 16'sd3611;
            6'd22: sine = 16'sd3405;
            6'd23: sine = 16'sd3165;
            6'd24: sine = 16'sd2896;
            6'd25: sine = 16'sd2598;
            6'd26: sine = 16'sd2275;
            6'd27: sine = 16'sd1930;
            6'd28: sine = 16'sd1567;
            6'd29: sine = 16'sd1189;
            6'd30: sine = 16'sd799;
            6'd31: sine = 16'sd401;
            6'd32: sine = 16'sd0;
            6'd33: sine = -16'sd401;
            6'd34: sine = -16'sd799;
            6'd35: sine = -16'sd1189;
            6'd36: sine = -16'sd1567;
            6'd37: sine = -16'sd1930;
            6'd38: sine = -16'sd2275;
            6'd39: sine = -16'sd2598;
            6'd40: sine = -16'sd2896;
            6'd41: sine = -16'sd3165;
            6'd42: sine = -16'sd3405;
            6'd43: sine = -16'sd3611;
            6'd44: sine = -16'sd3783;
            6'd45: sine = -16'sd3919;
            6'd46: sine = -16'sd4016;
            6'd47: sine = -16'sd4075;
            6'd48: sine = -16'sd4095;
            6'd49: sine = -16'sd4075;
            6'd50: sine = -16'sd4016;
            6'd51: sine = -16'sd3919;
            6'd52: sine = -16'sd3783;
            6'd53: sine = -16'sd3611;
            6'd54: sine = -16'sd3405;
            6'd55: sine = -16'sd3165;
            6'd56: sine = -16'sd2896;
            6'd57: sine = -16'sd2598;
            6'd58: sine = -16'sd2275;
            6'd59: sine = -16'sd1930;
            6'd60: sine = -16'sd1567;
            6'd61: sine = -16'sd1189;
            6'd62: sine = -16'sd799;
            6'd63: sine = -16'sd401;
 default: sine=16'sd0;
 endcase end
endfunction
always @(posedge clk or posedge rst) begin
 if(rst) begin
  sample_acc<=0;phase<=0;gain<=0;acr_count<=0;
  audio_valid<=0;audio_left<=0;audio_right<=0;acr_valid<=0;
 end else begin
  audio_valid<=0;acr_valid<=0;
  if(sample_acc>=27'd74118667) begin
   sample_acc<=sample_acc-27'd74118667;
   phase<=phase+phase_step;
   audio_valid<=1;
   audio_left<=scaled[23:0];audio_right<=scaled[23:0];
   if(image_valid && gain!=255) gain<=gain+1'b1;
   else if(!image_valid && gain!=0) gain<=gain-1'b1;
   if(acr_count==47) begin acr_count<=0;acr_valid<=1;end
   else acr_count<=acr_count+1'b1;
  end else sample_acc<=sample_acc+27'd48000;
 end
end
endmodule
