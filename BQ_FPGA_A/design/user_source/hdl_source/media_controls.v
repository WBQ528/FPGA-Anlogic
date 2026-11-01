// E1/E4: all inputs synchronized and debounced in the pixel clock domain.
// SW1 debug, SW2 settings, SW3 waveform, SW4 clean view. All low is default.
// Settings: KEY2 minus, KEY3 select, KEY4 plus. Playback keys suppressed until
// all buttons are released after leaving settings. No combinational clocks.
module media_controls #(parameter integer DEBOUNCE_CYCLES=1483333, parameter REMOTE_ENABLE=0)(
 input clk,rst,input [3:0] switches,input next_n,select_n,plus_n,
 output reg [3:0] options,output reg [2:0] selected,
 output reg signed [3:0] brightness,output reg [2:0] contrast,
 output reg [3:0] volume,output reg [1:0] fit,effect,output reg [2:0] zoom,output reg effect_auto,
 input remote_valid,input [3:0] remote_field,input [7:0] remote_value,
 output reg photo_muted,caption_enabled,output reg [1:0] caption_motion,output reg [5:0] caption_speed,
 output playback_next_n,playback_select_n,playback_plus_n
);
reg [6:0] sync0,sync1,stable;
localparam COUNT_BITS=DEBOUNCE_CYCLES<2?1:$clog2(DEBOUNCE_CYCLES);
reg [COUNT_BITS-1:0] count[0:6];
reg [6:0] terminal;
reg [2:0] keys_d;
reg playback_armed;
reg [2:0] press;
wire remote_apply=REMOTE_ENABLE && remote_valid;
reg [3:0] previous_switches;
wire menu=options[1];
wire menu_sync=(sync1[1]!=stable[1])?sync1[1]:menu;
integer k;
always @(posedge clk or posedge rst)begin
 if(rst)begin
  sync0<=7'b1110000;sync1<=7'b1110000;stable<=7'b1110000;
  keys_d<=3'b111;press<=0;options<=0;selected<=0;brightness<=0;contrast<=2;
  playback_armed<=0;fit<=0;effect<=0;effect_auto<=1;zoom<=2;volume<=10;
  previous_switches<=0;photo_muted<=0;caption_enabled<=1;caption_motion<=2;caption_speed<=4;
  terminal<=0;for(k=0;k<7;k=k+1)count[k]<=0;
 end else begin
  sync0<={plus_n,select_n,next_n,switches};sync1<=sync0;
  for(k=0;k<7;k=k+1)begin
   // Predict the terminal count one cycle ahead; preserve the exact debounce
   // duration without cascading a wide compare into the counter increment.
   terminal[k]<=sync1[k]!=stable[k] && count[k]==DEBOUNCE_CYCLES-2;
   if(sync1[k]==stable[k])count[k]<=0;
   else if(terminal[k] || DEBOUNCE_CYCLES<=1)begin stable[k]<=sync1[k];count[k]<=0;end
   else count[k]<=count[k]+1'b1;
  end
  previous_switches<=stable[3:0];
  for(k=0;k<4;k=k+1)if(previous_switches[k]!=stable[k])options[k]<=stable[k];
  keys_d<=stable[6:4];press<=keys_d & ~stable[6:4];
  if(menu_sync || menu)playback_armed<=0;
  else if(stable[6:4]==3'b111 && sync1[6:4]==3'b111)playback_armed<=1;
  if(menu)begin
   if(press[1])selected<=selected==5?3'd0:selected+1'b1;
   else if(press[0] && !press[2])begin
    if(selected==0 && brightness > -4)brightness<=brightness-1'b1;
    if(selected==1 && contrast!=0)contrast<=contrast-1'b1;
    if(selected==2 && fit!=0)fit<=fit-1'b1;
    if(selected==3 && zoom!=0)zoom<=zoom-1'b1;
    if(selected==4)begin effect_auto<=0;if(effect!=0)effect<=effect-1'b1;end
    if(selected==5 && volume!=0)volume<=volume-1'b1;
   end else if(press[2] && !press[0])begin
    if(selected==0 && brightness < 4)brightness<=brightness+1'b1;
    if(selected==1 && contrast<4)contrast<=contrast+1'b1;
    if(selected==2 && fit<2)fit<=fit+1'b1;
    if(selected==3 && zoom<4)zoom<=zoom+1'b1;
    if(selected==4)begin effect_auto<=0;if(effect<3)effect<=effect+1'b1;end
    if(selected==5 && volume<10)volume<=volume+1'b1;
   end
  end
  // Remote absolute writes follow local edits on the same clock edge.
  // Physical switch edges can subsequently reclaim their individual option.
  if(remote_apply)case(remote_field)
   0:brightness<=remote_value[3:0];1:contrast<=remote_value[2:0];
   2:fit<=remote_value[1:0];3:zoom<=remote_value[2:0];4:begin effect<=remote_value[1:0];effect_auto<=0;end
   5:volume<=remote_value[3:0];6:options<=remote_value[3:0];7:photo_muted<=remote_value[0];
   8:caption_enabled<=remote_value[0];9:caption_motion<=remote_value[1:0];10:caption_speed<=remote_value[5:0];
   15:begin brightness<=0;contrast<=2;fit<=0;zoom<=2;effect<=0;effect_auto<=1;volume<=10;options<=stable[3:0];photo_muted<=0;caption_enabled<=1;caption_motion<=2;caption_speed<=4;end
   default:begin end
  endcase
 end
end
// Use synchronized physical levels so existing debouncers keep their contract.
assign playback_next_n=playback_armed && !menu_sync ? sync1[4] : 1'b1;
assign playback_select_n=playback_armed && !menu_sync ? sync1[5] : 1'b1;
assign playback_plus_n=playback_armed && !menu_sync ? sync1[6] : 1'b1;
endmodule
