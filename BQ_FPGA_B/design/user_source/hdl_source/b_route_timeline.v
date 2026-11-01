// Entire route animation is computed from A's media clock, not wall time.
// Arbitrary jumps are deterministic, and pause freezes every route parameter.
module b_route_timeline(input clk,input [31:0] time_ms,output reg [3:0] segment,
 output reg [8:0] fraction,output reg [10:0] cursor_x,output reg [9:0] cursor_y);
reg [16:0] delta_q;reg [3:0] segment_q;
always @(posedge clk)begin delta_q<=delta;segment_q<=selected_segment;end
reg [3:0] selected_segment;reg [8:0] selected_fraction;reg [16:0] start_ms,delta;
wire [16:0] bounded_ms=time_ms>72000 ? 17'd72000:time_ms[16:0];reg moving;
reg signed [10:0] ax,ay,bx,by;reg signed [17:0] xx,yy;
always @*begin
 selected_segment=0;start_ms=16000;moving=0;
 if(bounded_ms<16000)begin selected_segment=0;start_ms=16000;moving=0;end
 else if(bounded_ms<18000)begin selected_segment=0;start_ms=16000;moving=1;end
 else if(bounded_ms<20000)begin selected_segment=1;start_ms=18000;moving=1;end
 else if(bounded_ms<33000)begin selected_segment=2;start_ms=33000;moving=0;end
 else if(bounded_ms<35000)begin selected_segment=2;start_ms=33000;moving=1;end
 else if(bounded_ms<37000)begin selected_segment=3;start_ms=35000;moving=1;end
 else if(bounded_ms<53000)begin selected_segment=4;start_ms=53000;moving=0;end
 else if(bounded_ms<55000)begin selected_segment=4;start_ms=53000;moving=1;end
 else if(bounded_ms<57000)begin selected_segment=5;start_ms=55000;moving=1;end
 else if(bounded_ms<68000)begin selected_segment=6;start_ms=68000;moving=0;end
 else if(bounded_ms<70000)begin selected_segment=6;start_ms=68000;moving=1;end
 else begin selected_segment=7;start_ms=70000;moving=1;end
 delta=moving?bounded_ms-start_ms:0;
 // 33/256 maps a two-second transition to 257 steps; endpoint saturates.
 selected_fraction=delta_q>=1986?9'd256:(((delta_q<<5)+delta_q)>>8);
 case(segment_q)
 0:begin ax=496;ay=466;bx=553;by=435;end
 1:begin ax=553;ay=435;bx=587;by=415;end
 2:begin ax=587;ay=415;bx=543;by=382;end
 3:begin ax=543;ay=382;bx=469;by=402;end
 4:begin ax=469;ay=402;bx=405;by=424;end
 5:begin ax=405;ay=424;bx=337;by=381;end
 6:begin ax=337;ay=381;bx=286;by=344;end
 default:begin ax=286;ay=344;bx=242;by=306;end
 endcase

end
reg signed [10:0] ax_d,ay_d,ax_p,ay_p;reg signed [7:0] dx_d,dy_d;
reg [8:0] fraction_d;reg [3:0] seg_d,seg_p;
always @(posedge clk)begin
 ax_d<=ax;ay_d<=ay;dx_d<=bx-ax;dy_d<=by-ay;fraction_d<=selected_fraction;seg_d<=segment_q;
 xx<=dx_d*$signed({1'b0,fraction_d});yy<=dy_d*$signed({1'b0,fraction_d});ax_p<=ax_d;ay_p<=ay_d;seg_p<=seg_d;
 cursor_x<=ax_p+(xx>>>8);cursor_y<=ay_p+(yy>>>8);segment<=seg_p;fraction<=fraction_d;
end
endmodule
