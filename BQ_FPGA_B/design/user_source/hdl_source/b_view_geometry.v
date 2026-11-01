// Contain a native-aspect photograph in the garden photo pane. A serial
// divider runs only during vertical blank; per-pixel scaling uses phase adds.
module b_view_geometry(input clk,rst,start,input [1:0] page,input [10:0] native_width,native_height,
 output reg ready,output reg [10:0] left,width,output reg [9:0] top,height,
 output reg [23:0] step_x,step_y);
reg [3:0] state;reg [10:0] nw,nh;reg fit_width;reg [1:0] page_q;
reg [20:0] lhs,rhs;reg launch;reg [23:0] numerator;reg [15:0] denominator;
wire done,busy,err;wire [23:0] quotient;
serial_divide divide(.clk(clk),.rst(rst),.start(launch),.numerator(numerator),.denominator(denominator),.busy(busy),.done(done),.error(err),.quotient(quotient));
always @(posedge clk)begin lhs<=nw*21'd528;rhs<=nh*21'd896;end
always @(posedge clk or posedge rst)begin
 if(rst)begin state<=0;ready<=0;left<=0;top<=0;width<=1280;height<=720;step_x<=4096;step_y<=4096;launch<=0;numerator<=0;denominator<=1;nw<=1280;nh<=720;fit_width<=1;page_q<=0;end
 else begin
  launch<=0;
  case(state)
   0:if(start)begin ready<=0;page_q<=page;nw<=native_width==0 ? 11'd1280:native_width;nh<=native_height==0 ? 11'd720:native_height;state<=1;end
   1:state<=2;
   2:if(page_q==0)begin left<=0;top<=0;width<=1280;height<=720;step_x<=4096;step_y<=4096;ready<=1;state<=0;end
     else if(page_q==2)begin left<=32;top<=88;width<=800;height<=450;step_x<=6553;step_y<=6553;ready<=1;state<=0;end
     else begin fit_width<=lhs>=rhs;state<=3;end
   3:begin numerator<=fit_width ? {3'd0,rhs}:{3'd0,lhs};denominator<=fit_width ? {5'd0,nw}:{5'd0,nh};launch<=1;state<=4;end
   4:if(done)begin width<=fit_width ? 11'd896:quotient[10:0];height<=fit_width ? quotient[9:0]:10'd528;state<=5;end
   5:begin left<=32+(11'd896-width)/2;top<=112+(10'd528-height)/2;numerator<=5242880;denominator<={5'd0,width};launch<=1;state<=6;end
   6:if(done)begin step_x<=quotient;state<=7;end
   7:begin numerator<=2949120;denominator<={6'd0,height};launch<=1;state<=8;end
   8:if(done)begin step_y<=quotient;ready<=1;state<=0;end
   default:state<=0;
  endcase
 end
end
endmodule
