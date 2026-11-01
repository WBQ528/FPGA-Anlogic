// R6: 115200 8N1 on the fixed 50 MHz board clock. No FIFO or block RAM.
module hmi_uart #(parameter integer CLOCK_HZ=50000000,BAUD=115200)(
 input clk,rst,rx,output reg tx,
 output reg rx_valid,output reg [7:0] rx_data,output reg rx_error,
 input tx_start,input [7:0] tx_data,output reg tx_busy
);
localparam integer DIV=(CLOCK_HZ+BAUD/2)/BAUD;
localparam integer CW=$clog2(DIV+1);
(* async_reg="true" *) reg [1:0] rx_sync;
reg [1:0] rs;reg [CW-1:0] rc,tc;reg [3:0] rb,tb;
reg [7:0] rshift;reg [9:0] tshift;
always @(posedge clk or posedge rst)begin
 if(rst)begin rx_sync<=3;rs<=0;rc<=0;rb<=0;rshift<=0;rx_valid<=0;rx_data<=0;rx_error<=0;end
 else begin
  rx_sync<={rx_sync[0],rx};rx_valid<=0;rx_error<=0;
  case(rs)
   0:if(!rx_sync[1])begin rc<=DIV/2-1;rs<=1;end
   1:if(rc!=0)rc<=rc-1'b1;else if(rx_sync[1])rs<=0;else begin rc<=DIV-1;rb<=0;rs<=2;end
   2:if(rc!=0)rc<=rc-1'b1;else begin rshift[rb]<=rx_sync[1];rc<=DIV-1;if(rb==7)rs<=3;else rb<=rb+1'b1;end
   3:if(rc!=0)rc<=rc-1'b1;else begin
    if(rx_sync[1])begin rx_data<=rshift;rx_valid<=1;end else rx_error<=1;
    rs<=0;
   end
   default:rs<=0;
  endcase
 end
end
always @(posedge clk or posedge rst)begin
 if(rst)begin tx<=1;tx_busy<=0;tc<=0;tb<=0;tshift<=10'h3ff;end
 else if(!tx_busy)begin
  tx<=1;
  if(tx_start)begin tshift<={1'b1,tx_data,1'b0};tx<=0;tx_busy<=1;tc<=DIV-1;tb<=0;end
 end else if(tc!=0)tc<=tc-1'b1;
 else if(tb==9)begin tx<=1;tx_busy<=0;end
 else begin tshift<={1'b1,tshift[9:1]};tx<=tshift[1];tb<=tb+1'b1;tc<=DIV-1;end
end
endmodule
