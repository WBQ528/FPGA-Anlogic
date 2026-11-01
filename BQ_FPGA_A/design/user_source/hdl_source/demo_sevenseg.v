// OPT-001: all status inputs and scan logic in video clock domain (25MHz).
// Photo: P1 0500 (manual/image 1/500Hz), A2 0750 (auto/image 2/750Hz).
// Dwell is shown for one second after KEY3: t 0001/0003/0005.
// Movie: rA MM.SS (run/audio), PA MM.SS (pause), dA MM.SS (end).
// '-' in audio position means muted. E + code overrides normal page.
module demo_sevenseg #(parameter CLK_HZ=25000000, VIDEO_FPS=30)(
 input clk,rst,movie_mode,valid,input [3:0] image_id,input photo_music,input [1:0] period,
 input auto_play,input [3:0] error_code,
 input paused,muted,ended,input [15:0] movie_frame,
 output [5:0] seg_sel,output [7:0] seg_data
);
reg [1:0] previous_period;
localparam DWELL_BITS=$clog2(CLK_HZ+1);
reg [DWELL_BITS-1:0] dwell_timer;
reg [15:0] previous_frame;
reg [4:0] subframe;
// Status changes only once per media frame. Register the comparison before
// the decimal rollover chain; the physical indicator is delayed one pixel tick.
reg time_clear,frame_advance;
always @(posedge clk or posedge rst)begin
 if(rst)begin time_clear<=1'b1;frame_advance<=1'b0;end
 else begin time_clear<=!movie_mode || movie_frame==0 || movie_frame<previous_frame;
 frame_advance<=movie_frame!=previous_frame && previous_frame!=0;end
end
reg [3:0] s0,s1,m0,m1;
reg [7:0] d0,d1,d2,d3,d4,d5;
function [7:0] digit;
 input [3:0] n;
 begin case(n)
 0:digit=8'hc0;1:digit=8'hf9;2:digit=8'ha4;3:digit=8'hb0;
 4:digit=8'h99;5:digit=8'h92;6:digit=8'h82;7:digit=8'hf8;
 8:digit=8'h80;9:digit=8'h90;10:digit=8'h88;11:digit=8'h83;
 12:digit=8'hc6;13:digit=8'ha1;14:digit=8'h86;default:digit=8'h8e;
 endcase end
endfunction
always @(posedge clk or posedge rst)begin
 if(rst)begin
  previous_period<=1;dwell_timer<=0;previous_frame<=0;
  subframe<=0;s0<=0;s1<=0;m0<=0;m1<=0;
 end else begin
  previous_period<=period;
  if(period!=previous_period && !movie_mode)dwell_timer<=CLK_HZ;
  else if(dwell_timer!=0)dwell_timer<=dwell_timer-1'b1;
  previous_frame<=movie_frame;
  if(time_clear)begin
   subframe<=0;s0<=0;s1<=0;m0<=0;m1<=0;
  end else if(frame_advance)begin
   if(subframe==VIDEO_FPS-1)begin
    subframe<=0;
    if(s0==9)begin s0<=0;
     if(s1==5)begin s1<=0;
      if(m0==9)begin m0<=0;m1<=m1==9 ? 0 : m1+1'b1;end
      else m0<=m0+1'b1;
     end else s1<=s1+1'b1;
    end else s0<=s0+1'b1;
   end else subframe<=subframe+1'b1;
  end
 end
end
always @* begin
 d0=paused ? 8'h89 : auto_play ? 8'h88 : 8'h8c;d1=digit({2'd0,image_id}+1'b1);
 d2=digit(0);d3=digit(5);d4=digit(0);d5=digit(0);
 case(image_id[1:0])
 1:begin d3=digit(7);d4=digit(5);end
 2:begin d2=digit(1);d3=digit(0);end
 3:begin d2=digit(1);d3=digit(5);end
 default:;
 endcase
 if(photo_music)begin
  d1=digit(image_id>=9?1:0);d2=digit(image_id>=9?image_id-9:image_id+1);
  d3=8'hbf;d4=8'hc8;d5=8'hc1;
 end
 if(dwell_timer!=0)begin
  d0=8'h87;d1=8'hff;d2=digit(0);d3=digit(0);d4=digit(0);
  d5=digit(period==0 ? 4'd1 : period==1 ? 4'd3 : 4'd5);
 end
 if(movie_mode)begin
  d0=paused ? 8'h8c : ended ? 8'ha1 : 8'haf;
  d1=muted ? 8'hbf : 8'h88;
  d2=digit(m1);d3=digit(m0)&8'h7f;d4=digit(s1);d5=digit(s0);
 end
 if(!valid)begin d0=8'hc7;d1=8'hbf;d2=8'hbf;d3=8'hbf;d4=8'hbf;d5=8'hbf;end
 if(error_code>=4'hb)begin
  d0=8'h86;d1=digit(error_code);d2=8'hff;d3=8'hff;d4=8'hff;d5=8'hff;
 end
end
// Separate status/digit formatting from the multiplexed physical outputs.
reg [47:0] digits;
always @(posedge clk)digits<={d5,d4,d3,d2,d1,d0};
seg_scan #(.CLK_FREQ(CLK_HZ)) scan(.clk(clk),.rst_n(!rst),.seg_sel(seg_sel),.seg_data(seg_data),
 .seg_data_0(digits[7:0]),.seg_data_1(digits[15:8]),.seg_data_2(digits[23:16]),.seg_data_3(digits[31:24]),.seg_data_4(digits[39:32]),.seg_data_5(digits[47:40]));
endmodule
