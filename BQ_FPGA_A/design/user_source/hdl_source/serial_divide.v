// Unsigned restoring divider, 24 cycles; configuration use only, no pixel stall.
// Start accepted only while idle. Division by zero returns all ones + error.
module serial_divide(input clk,rst,start,input [23:0] numerator,input [15:0] denominator,
 output reg busy,done,error,output reg [23:0] quotient);
reg [23:0] work;reg [16:0] remainder;reg [15:0] divisor;reg [4:0] count;
wire [16:0] shifted={remainder[15:0],work[23]};
wire subtract=shifted>={1'b0,divisor};
always @(posedge clk or posedge rst)begin
 if(rst)begin busy<=0;done<=0;error<=0;quotient<=0;work<=0;remainder<=0;divisor<=0;count<=0;end
 else begin
  done<=0;
  if(start && !busy)begin
   error<=denominator==0;divisor<=denominator;work<=numerator;remainder<=0;count<=0;
   if(denominator==0)begin quotient<=24'hffffff;done<=1;end else busy<=1;
  end else if(busy)begin
   remainder<=subtract?shifted-{1'b0,divisor}:shifted;
   work<={work[22:0],subtract};count<=count+1'b1;
   if(count==23)begin busy<=0;done<=1;quotient<={work[22:0],subtract};end
  end
 end
end
endmodule
