// Two-pixel-clock compositor; sync signals travel with the original pixels.
// Metadata is immutable after header validation until reset, across clock domains.
module e1_overlay #(parameter EXTERNAL_CAPTION=0)(
 input clk,rst,hs,vs,de,input [23:0] rgb,
 input [3:0] options,input [2:0] selected,input [1:0] fit,effect,input [2:0] zoom,input signed [3:0] brightness,input [2:0] contrast,
 input [3:0] volume,input caption_external,input movie_mode,input [15:0] movie_frame,movie_stalls,
 input movie_paused,movie_muted,movie_ended,input [3:0] movie_error,
 input [10:0] native_width,native_height,input [15:0] display_underruns,
 input image_valid,input [3:0] image_id,input [4:0] image_count,input photo_music,input [10:0] status,
 input source_clk,source_rst,ui_write,input [8:0] ui_address,input [7:0] ui_data,
 input ui_loaded,input [12:0] total_frames,
 output [23:0] out_rgb,output out_hs,out_vs,out_de
);
// R5 one front stage: precompute pause colors independently of UI priority.
// RGB and sync travel together; coordinates count these delayed sync signals.
reg hs_pre,vs_pre,de_pre;reg [23:0] rgb_pre,shade_pre,tile_pre,edge_pre,bars_pre;
wire [23:0] shade_color=blend(rgb,24'h080f18,1);
wire [23:0] tile_color=blend(shade_color,24'he9f0f4,2);
always @(posedge clk)begin
 hs_pre<=hs;vs_pre<=vs;de_pre<=de && !rst;rgb_pre<=rgb;
 shade_pre<=shade_color;tile_pre<=tile_color;
 edge_pre<=blend(tile_color,24'hffffff,1);bars_pre<=blend(tile_color,24'h142330,2);
end

`include "ui_label_ids.vh"
reg [7:0] metadata[0:511];
reg [15:0] cue_start[0:11],cue_end[0:11];
reg [31:0] signature;
reg [3:0] cue_count;
reg [6:0] ticker_length;
integer i,j;
always @(posedge source_clk)if(ui_write)metadata[ui_address]<=ui_data;
always @(posedge source_clk or posedge source_rst)begin
 if(source_rst)begin
  signature<=0;cue_count<=0;ticker_length<=0;
  for(i=0;i<12;i=i+1)begin cue_start[i]<=0;cue_end[i]<=0;end
 end else if(ui_write)begin
  if(ui_address>=32 && ui_address<36)signature<={ui_data,signature[31:8]};
  if(ui_address==36)cue_count<=ui_data<=12?ui_data[3:0]:0;
  if(ui_address==38)ticker_length<=ui_data<=64?ui_data[6:0]:0;
  if(ui_address>=128)case(ui_address[4:0])
   0:cue_start[ui_address[8:5]-4][7:0]<=ui_data;
   1:cue_start[ui_address[8:5]-4][15:8]<=ui_data;
   2:cue_end[ui_address[8:5]-4][7:0]<=ui_data;
   3:cue_end[ui_address[8:5]-4][15:8]<=ui_data;
   default:;
  endcase
 end
end
reg view_caption,view_movie,view_paused,view_muted,view_ended,view_valid,view_error;
wire external_caption_active=EXTERNAL_CAPTION || view_caption;
reg [3:0] view_options,view_volume;
reg [2:0] view_selected,view_zoom;reg [1:0] view_fit,view_effect;reg signed [3:0] view_brightness;reg [2:0] view_contrast;
reg [3:0] view_image;reg [4:0] view_count;reg view_music;
reg [10:0] view_status;
reg [15:0] view_stalls;
reg [1:0] loaded_sync;
reg [10:0] physical_x;wire [9:0] x=physical_x[10:1];reg [1:0] row_phase;reg [8:0] y;
reg de_d,vs_d;
wire frame_start=vs_d && !vs_pre;
reg [3:0] active_cue;
reg cue_visible,metadata_active;
reg [10:0] scroll;
reg [7:0] toast_timer;
reg [3:0] toast_kind;
reg [10:0] previous_controls;
wire [10:0] controls={movie_mode,movie_paused,movie_muted,status[9:7],image_id,image_valid};
reg [15:0] frame_seen;
reg [13:0] progress_acc;
reg [9:0] progress;
reg [4:0] subframe;
reg [3:0] sec0,sec1,min0,min1;
wire error_present=movie_mode ? movie_error!=0 : status[6:3]>=4'hb;
always @(posedge clk or posedge rst)begin
 if(rst)begin
  loaded_sync<=0;physical_x<=0;y<=0;row_phase<=0;de_d<=0;vs_d<=1;
  active_cue<=0;cue_visible<=0;metadata_active<=0;scroll<=0;
  toast_timer<=0;toast_kind<=0;previous_controls<=0;
  frame_seen<=0;progress<=0;progress_acc<=0;subframe<=0;sec0<=0;sec1<=0;min0<=0;min1<=0;
 end else begin
  loaded_sync<={loaded_sync[0],ui_loaded};de_d<=de_pre;vs_d<=vs_pre;
  if(!vs_pre)begin physical_x<=0;y<=0;row_phase<=0;end
  else if(de_pre)begin if(physical_x<1279)physical_x<=physical_x+1'b1;end
  else begin physical_x<=0;if(de_d)begin if(row_phase!=0)y<=y+1'b1;row_phase<=row_phase==2?0:row_phase+1'b1;end end
  // Repeated subtraction, bounded to 576 clocks and completed in blanking.
  if(progress_acc>=total_frames && total_frames!=0 && progress<576)begin
   progress<=progress+1'b1;progress_acc<=progress_acc-total_frames;
  end
  if(frame_start)begin
   metadata_active<=loaded_sync[1] && signature==32'h31454955;
   cue_visible<=0;
   if(loaded_sync[1] && signature==32'h31454955)begin
    for(j=0;j<12;j=j+1)if(j<cue_count && movie_frame!=0 &&
     movie_frame-1>=cue_start[j] && movie_frame-1<cue_end[j])begin active_cue<=j;cue_visible<=1;end
   end
   if(!(movie_mode?movie_paused:status[10]))begin
    if(scroll>=575)scroll<=0;else scroll<=scroll+1'b1;
   end
   previous_controls<=controls;
   if(toast_timer!=0)toast_timer<=toast_timer-1'b1;
   if(view_movie==movie_mode && image_valid && previous_controls[0] && controls!=previous_controls)begin
    toast_timer<=120;
    if(movie_mode)begin
     if(movie_paused!=previous_controls[9])begin toast_kind<=movie_paused?1:2;toast_timer<=0;end
     else toast_kind<=movie_muted?3:4;
    end else if(image_id!=previous_controls[4:1])begin toast_kind<=0;toast_timer<=0;end
    else if(status[8:7]!=previous_controls[6:5])toast_kind<=6;
    else begin toast_kind<=status[9]?7:8;toast_timer<=0;end
   end
   if(!movie_mode || movie_frame<frame_seen)begin
    frame_seen<=0;progress<=0;progress_acc<=0;subframe<=0;sec0<=0;sec1<=0;min0<=0;min1<=0;
   end else if(movie_frame!=frame_seen)begin
    frame_seen<=movie_frame;progress_acc<=progress_acc+576;
    if(frame_seen!=0)begin
     if(subframe==23)begin
      subframe<=0;
      if(sec0==9)begin sec0<=0;
       if(sec1==5)begin sec1<=0;
        if(min0==9)begin min0<=0;min1<=min1+1'b1;end else min0<=min0+1'b1;
       end else sec1<=sec1+1'b1;
      end else sec0<=sec0+1'b1;
     end else subframe<=subframe+1'b1;
    end
   end
  end
 end
end
// All visible control fields are sampled in vertical blanking.
always @(posedge clk or posedge rst)begin
 if(rst)begin view_movie<=0;view_paused<=0;view_muted<=0;view_ended<=0;
  view_caption<=0;view_volume<=10;view_options<=0;view_selected<=0;view_brightness<=0;view_contrast<=2;view_fit<=0;view_zoom<=2;view_effect<=0;
  view_valid<=0;view_error<=0;view_image<=0;view_status<=0;view_stalls<=0;view_count<=0;view_music<=0;end
 else if(frame_start)begin
  view_caption<=caption_external;view_volume<=volume;view_options<=options;view_selected<=selected;view_brightness<=brightness;view_contrast<=contrast;view_fit<=fit;view_zoom<=zoom;view_effect<=effect;
  view_movie<=movie_mode;view_paused<=movie_paused;view_muted<=movie_muted;view_ended<=movie_ended;
  view_valid<=image_valid;view_error<=error_present;view_image<=image_id;view_count<=image_count;view_music<=photo_music;view_status<=status;view_stalls<=movie_stalls;
 end
end
// Dimensions come from the validated BMP header, latched at frame boundary.
reg [10:0] binary_w,binary_h;reg [15:0] bcd_w,bcd_h;reg [3:0] bcd_count;
function [15:0] decimal_step;input [15:0] value;input bit_in;reg [15:0] b;integer n;begin
 b=value;for(n=0;n<4;n=n+1)if(b[n*4+:4]>=5)b[n*4+:4]=b[n*4+:4]+3;
 decimal_step={b[14:0],bit_in};end endfunction
always @(posedge clk or posedge rst)begin
 if(rst)begin binary_w<=0;binary_h<=0;bcd_w<=0;bcd_h<=0;bcd_count<=0;end
 else if(frame_start)begin binary_w<=movie_mode?11'd960:native_width;binary_h<=movie_mode?11'd540:native_height;
  bcd_w<=0;bcd_h<=0;bcd_count<=11;end
 else if(bcd_count!=0)begin bcd_w<=decimal_step(bcd_w,binary_w[10]);bcd_h<=decimal_step(bcd_h,binary_h[10]);
  binary_w<=binary_w<<1;binary_h<=binary_h<<1;bcd_count<=bcd_count-1'b1;end
end
function [7:0] ascii;
 input [7:0] value;begin ascii=value-32;end
endfunction
function [7:0] blend_channel;
 input [7:0] a,b;input [1:0] coverage;reg [9:0] sum;
 begin case(coverage)
  0:blend_channel=a;
  1:begin sum={a,1'b0}+a+b;blend_channel=sum[9:2];end
  2:begin sum={2'b0,a}+b;blend_channel=sum[8:1];end
  3:blend_channel=b;
 endcase end
endfunction
function [23:0] blend;
 input [23:0] a,b;input [1:0] c;
 begin blend={blend_channel(a[23:16],b[23:16],c),blend_channel(a[15:8],b[15:8],c),blend_channel(a[7:0],b[7:0],c)};end
endfunction
reg [23:0] background,foreground;
reg [7:0] fixed_glyph;
reg dynamic_glyph,font_enable,toast_pixel;
reg [8:0] meta_address;
reg [4:0] font_row;
reg [2:0] font_col;
reg [9:0] local_x;
reg [10:0] ticker_x;
reg [5:0] character;
reg [5:0] label;reg static_glyph;
reg [1:0] fade;
wire screen_paused=view_movie?view_paused:view_status[10];
wire [3:0] brightness_magnitude=view_brightness[3]?(~view_brightness+4'd1):view_brightness;
wire [3:0] brightness_bar=4'd4+view_brightness;
wire [9:0] pause_dx=x>=320?x-320:320-x;
wire [8:0] pause_dy=y>=240?y-240:240-y;
function [5:0] tile_halfwidth;
 input [5:0] dy;
 begin case(dy)
  0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16:tile_halfwidth=40;
  17,18,19,20,21:tile_halfwidth=39;
  22,23:tile_halfwidth=38;
  24,25:tile_halfwidth=37;
  26:tile_halfwidth=36;27:tile_halfwidth=35;28:tile_halfwidth=34;
  29:tile_halfwidth=32;30:tile_halfwidth=30;31:tile_halfwidth=27;
  default:tile_halfwidth=0;
 endcase end
endfunction

wire [9:0] toast_origin=toast_kind==6?10'd264:(toast_kind==1 || toast_kind==3)?10'd296:toast_kind==4?10'd280:10'd288;
// Coordinates are unsigned and bounded to 640x480 logical pixels. Sized
// operands avoid 32-bit subtract/multiply chains in per-pixel comparisons.
wire [8:0] menu_top=9'd140+view_selected*9'd40;
wire [8:0] menu_bottom=9'd176+view_selected*9'd40;
always @*begin
 background=rgb_pre;foreground=24'hecf4fa;fixed_glyph=0;dynamic_glyph=0;
 static_glyph=0;meta_address=0;font_row=0;font_col=0;font_enable=0;toast_pixel=0;
 local_x=0;ticker_x=0;character=0;label=L_PLAY;fade=3;
 if(de_pre)begin
  if(screen_paused && view_valid && y>=60 && y<420)background=shade_pre;
  if(!view_options[3] || view_error || !view_valid)begin
  if(view_movie && (y<36 || y>=448))background=24'h0e151d;
  if(!view_movie && (y<36 || y>=448))background=24'h0e151d;
  if(view_options[0] && y>=36 && y<60)background=24'h0e151d;
  if(view_options[0] && y==59 && x>=24 && x<616)background=24'h24313c;
  // Compact cyan transport mark, separate from the title typography.
  if(x>=24 && x<40 && y>=18 && y<34)begin
   if(x-10'd24<y-9'd18 && x-10'd24<9'd33-y)background=24'h59dbc8;
  end
  if(x>=52 && x<244 && y>=12 && y<32)begin
   local_x=x-52;font_row=y-12;font_col=local_x[2:0];character=local_x[8:3];font_enable=1;
   if(view_movie && metadata_active)begin dynamic_glyph=1;meta_address=40+character;end
   else begin label=view_movie?L_DEFAULT_TITLE:L_PHOTO;static_glyph=1;end
  end
  if(x>=480 && x<624 && y>=12 && y<32)begin
   local_x=x-480;font_row=y-12;font_col=local_x[2:0];character=local_x[8:3];font_enable=1;
   if(view_error)label=L_ERROR;
   else if(!view_valid)label=L_LOAD;
   else if(view_movie)label=view_ended?L_END:view_paused?L_PAUSE:view_muted?L_MUTE:L_PLAY;
   else label=view_status[10]?L_PAUSE:view_status[9]?L_AUTO:L_MANUAL;
   static_glyph=1;foreground=view_error?24'hff958b:24'h59dbc8;
  end
  if(!view_movie && x>=336 && x<392 && y>=12 && y<32)begin
   local_x=x-336;font_row=y-12;font_col=local_x[2:0];character=local_x[8:3];font_enable=1;
   case(character)
    0:fixed_glyph=ascii(view_image>=9?"1":"0");
    1:fixed_glyph=ascii(8'd48+(view_image>=9?view_image-9:view_image+1));2:fixed_glyph=ascii("/");
    3:fixed_glyph=ascii(view_count>=10?"1":"0");4:fixed_glyph=ascii(8'd48+(view_count>=10?view_count-10:view_count));default:fixed_glyph=0;
   endcase
  end
  if(view_options[0] && x>=52 && x<436 && y>=36 && y<56)begin
   local_x=x-52;font_row=y-36;font_col=local_x[2:0];character=local_x[8:3];font_enable=1;
   foreground=24'h91a9b8;
   case(character)
    0,1,2,3:fixed_glyph=ascii(8'd48+((bcd_w >> ((3-character)*4)) & 15));
    4:fixed_glyph=ascii("x");
    5,6,7,8:fixed_glyph=ascii(8'd48+((bcd_h >> ((8-character)*4)) & 15));
    10:fixed_glyph=ascii("/");12:fixed_glyph=ascii(view_movie?"2":"P");13:fixed_glyph=ascii(view_movie?"4":"C");
    14:fixed_glyph=ascii(view_movie?"f":"M");15:fixed_glyph=ascii(view_movie?"p":"4");16:fixed_glyph=ascii(view_movie?"s":"8");
    18:fixed_glyph=ascii("/");20:fixed_glyph=ascii(view_movie?"4":view_status[8:7]==0?"1":view_status[8:7]==1?"3":"5");
    21:fixed_glyph=ascii(view_movie?"8":"s");22:fixed_glyph=view_movie?ascii("k"):0;
    24:fixed_glyph=ascii("/");26:fixed_glyph=ascii("V");27:fixed_glyph=ascii("O");28:fixed_glyph=ascii("L");
    30:fixed_glyph=view_volume==10?ascii("1"):0;
    31:fixed_glyph=ascii(8'd48+(view_volume==10?4'd0:view_volume));32:fixed_glyph=ascii("0");33:fixed_glyph=ascii("%");
    35:fixed_glyph=view_movie?ascii("U"):0;36:fixed_glyph=view_movie?ascii(48+(display_underruns==0?0:1)):0;
    default:fixed_glyph=0;
   endcase
  end
  if(view_movie && x>=400 && x<464 && y>=12 && y<32)begin
   local_x=x-400;font_row=y-12;font_col=local_x[2:0];character=local_x[8:3];font_enable=1;
   case(character)
    0:fixed_glyph=ascii(48+min1);1:fixed_glyph=ascii(48+min0);2:fixed_glyph=ascii(":");
    3:fixed_glyph=ascii(48+sec1);4:fixed_glyph=ascii(48+sec0);
    6:fixed_glyph=view_stalls!=0?ascii("!"):0;default:fixed_glyph=0;
   endcase
  end
  if(!external_caption_active && view_movie && cue_visible && metadata_active && x>=208 && x<432 && y>=424 && y<444)begin
   local_x=x-208;font_row=y-424;font_col=local_x[2:0];character=local_x[8:3];font_enable=1;
   dynamic_glyph=1;meta_address=132+{active_cue,5'd0}+character;
  end
  if(!external_caption_active && !view_movie && !view_options[1] && x>=24 && x<536 && y>=452 && y<472)begin
   local_x=x-24;font_row=y-452;font_col=local_x[2:0];character=local_x[8:3];font_enable=1;
   label=view_status[10]?L_PHOTO_PAUSE_HINT:view_status[9]?L_PHOTO_RUN_HINT:L_PHOTO_HINT;static_glyph=1;foreground=24'hecf4fa;
  end
  if(!external_caption_active && view_movie && !view_options[1] && metadata_active && x>=32 && x<608 && y>=456 && y<476)begin
   ticker_x={1'b0,x}-32+scroll;
   if(ticker_x>=576)ticker_x=ticker_x-576;
   if(ticker_x<{ticker_length,3'd0})begin
    local_x=ticker_x[9:0];font_row=y-456;font_col=local_x[2:0];font_enable=1;
    dynamic_glyph=1;meta_address=64+local_x[8:3];foreground=24'h91a9b8;
   end
  end
  if(view_options[1] && x>=24 && x<216 && y>=452 && y<472)begin
   local_x=x-24;font_row=y-452;font_col=local_x[2:0];character=local_x[8:3];font_enable=1;
   label=L_CLOSE_HINT;static_glyph=1;foreground=24'hecf4fa;
  end
  if(!external_caption_active && view_movie && x>=32 && x<608 && y>=449 && y<452)
   background=(x-10'd32<progress)?24'h59dbc8:24'h284653;
  end
  // Centered frosted light tile, matching the user's reference. Scene remains visible.
  if(screen_paused && view_valid && pause_dy<32 && pause_dx<=tile_halfwidth(pause_dy[5:0]))begin
   background=tile_pre;
   if(pause_dy>=30 || pause_dx==tile_halfwidth(pause_dy[5:0]))background=edge_pre;
   if(((x>=307 && x<315)||(x>=325 && x<333)) && y>=226 && y<254 &&
      !((y==226 || y==253) && (x==307 || x==314 || x==325 || x==332)))
    background=bars_pre;
  end
  if(toast_timer!=0 && x>=208 && x<432 && y>=76 && y<112 &&
   !((x<212 || x>=428) && (y<80 || y>=108)))begin
   background=24'h183640;static_glyph=0;toast_pixel=1;dynamic_glyph=0;font_enable=0;
   fade=toast_timer<8?1:toast_timer<16?2:3;
   if(x>=toast_origin && x<toast_origin+192 && y>=84 && y<104)begin
    local_x=x-toast_origin;font_row=y-84;font_col=local_x[2:0];character=local_x[8:3];font_enable=1;
    case(toast_kind)
     1:label=L_PAUSE;2:label=L_RESUME;3:label=L_MUTE;4:label=L_SOUND;
     5:label=L_NEXT;6:label=L_PERIOD;7:label=L_AUTO;default:label=L_MANUAL;
    endcase
    static_glyph=1;foreground=24'hecf4fa;
   end
  end
  // R2 settings: same selection index drives the values and visible marker.
  if(view_options[1] && x>=112 && x<528 && y>=96 && y<424)begin
   background=24'h142330;static_glyph=0;font_enable=0;dynamic_glyph=0;toast_pixel=0;
   if(x==112 || x==527 || y==96 || y==423)background=24'h42616b;
   if(x>=128 && x<512 && y>=menu_top && y<menu_bottom)begin
    background=24'h24454b;
    if(x<132)background=24'hffffff;
   end
   if(x>=144 && x<480 && ((y>=108 && y<128) || (y>=148 && y<168) ||
      (y>=188 && y<208) || (y>=228 && y<248) || (y>=268 && y<288) ||
      (y>=308 && y<328) || (y>=348 && y<368) || (y>=388 && y<408)))begin
    local_x=x-144;
    font_row=y>=388?y-388:y>=348?y-348:y>=308?y-308:y>=268?y-268:y>=228?y-228:y>=188?y-188:y>=148?y-148:y-108;
    font_col=local_x[2:0];character=local_x[8:3];font_enable=1;foreground=24'hffffff;
    if(y<140)begin label=L_SETTINGS;static_glyph=1;end
    else if(y<180)begin
     begin label=L_BRIGHTNESS;static_glyph=1;end
     if(character==19)begin static_glyph=0;fixed_glyph=ascii(view_brightness<0?"-":"+");end
     if(character==20)begin static_glyph=0;fixed_glyph=ascii(8'd48+brightness_magnitude);end
    end else if(y<220)begin
     begin label=L_CONTRAST;static_glyph=1;end
     if(character==19)begin static_glyph=0;fixed_glyph=ascii(8'd48+view_contrast);end
    end else if(y<260)begin
     begin label=view_fit==0?L_FIT_CONTAIN:view_fit==1?L_FIT_COVER:L_FIT_STRETCH;static_glyph=1;end
    end else if(y<300)begin
     begin label=view_zoom==0?L_SIZE_50:view_zoom==1?L_SIZE_75:view_zoom==2?L_SIZE_100:view_zoom==3?L_SIZE_125:L_SIZE_150;static_glyph=1;end
    end else if(y<340)begin
     begin label=view_effect==0?L_FX_BLINDS:view_effect==1?L_FX_CONVEYOR:view_effect==2?L_FX_RANDOM:L_FX_FLIP;static_glyph=1;end
    end else if(y<380)begin
     begin label=L_VOLUME;static_glyph=1;end
     if(character==18)begin static_glyph=0;fixed_glyph=view_volume==10?ascii("1"):0;end
     if(character==19)begin static_glyph=0;fixed_glyph=ascii(48+(view_volume==10?0:view_volume));end
     if(character==20)begin static_glyph=0;fixed_glyph=ascii("0");end if(character==21)begin static_glyph=0;fixed_glyph=ascii("%");end
    end else begin label=L_MENU_HINT;static_glyph=1;end
    if(character>=24)begin font_enable=0;fixed_glyph=0;static_glyph=0;end
   end
  end
 end
end
reg [7:0] metadata_q,glyph0;
reg static0;wire [7:0] static_q;
ui_label_rom labels(.clk(clk),.address({label,character}),.data(static_q));
reg dynamic0,enable0,enable1,toast0,toast1;
reg [4:0] row0;
reg [2:0] col0,col1;
reg [1:0] fade0,fade1;
reg [23:0] bg0,bg1,fg0,fg1,rgb0,rgb1;
reg [2:0] hs_pipe,vs_pipe,de_pipe;
reg [23:0] selected_rgb,original_rgb;
reg selected_toast;reg [1:0] selected_fade;
wire [7:0] selected_glyph=static0?static_q:dynamic0?metadata_q:glyph0;
wire [7:0] bounded_glyph=selected_glyph;
wire [3:0] packed_font_row=row0[3:0]-4'd4;
wire [12:0] font_address={1'b0,bounded_glyph,packed_font_row};
wire [15:0] font_bits;
ui_font_rom font(.clk(clk),.enable(enable0),.address(font_address),.data(font_bits));
always @(posedge clk)begin
 static0<=static_glyph;metadata_q<=metadata[meta_address];glyph0<=fixed_glyph;dynamic0<=dynamic_glyph;
 row0<=font_row;col0<=font_col;col1<=col0;
 enable0<=font_enable && font_row>=4 && font_row<20;enable1<=enable0;toast0<=toast_pixel;toast1<=toast0;
 fade0<=fade;fade1<=fade0;bg0<=background;bg1<=bg0;fg0<=foreground;fg1<=fg0;rgb0<=rgb_pre;rgb1<=rgb0;
 hs_pipe<={hs_pipe[1:0],hs_pre};vs_pipe<={vs_pipe[1:0],vs_pre};de_pipe<={de_pipe[1:0],de_pre && !rst};
 // Isolate the font RAM/mux from the toast blend arithmetic.
 selected_rgb<=composed;original_rgb<=rgb1;selected_toast<=toast1;selected_fade<=fade1;
end
// The compact UI atlas is binary coverage. Select foreground directly rather
// than rebuilding two-bit alpha arithmetic for duplicate 0/3 font bits.
wire font_ink=enable1 && font_bits[{col1,1'b0}];
wire [23:0] composed=font_ink?fg1:bg1;
assign out_rgb=selected_toast?blend(original_rgb,selected_rgb,selected_fade):selected_rgb;
assign out_hs=hs_pipe[2];assign out_vs=vs_pipe[2];assign out_de=de_pipe[2];
endmodule

`include "ui_label_rom.vh"
