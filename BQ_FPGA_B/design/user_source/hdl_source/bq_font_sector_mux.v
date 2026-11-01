// one-sector font mailbox sharing the existing native SD reader.
// Image request is LEVEL-held until image_end (existing FAT contract).
// Font request is a one-cycle pulse accepted only when !font_busy. Request LBA
// and result/error are bundled with toggle synchronizers and held until ACK.
// Font bytes remain immutable from done until the next accepted font request.
module bq_font_sector_mux #(
 parameter integer TIMEOUT_CYCLES=200000000, IMAGE_BUDGET=4
)(
 input sd_clk,sd_rst,
 input image_request,input [31:0] image_lba,input [4:0] image_count,input image_reset,
 output image_valid,image_end,output [7:0] image_data,output image_initialized,
 input native_initialized,native_valid,native_end,input [7:0] native_data,input [3:0] native_error,
 output reg native_request,output reg [31:0] native_lba,output reg [4:0] native_count,output reg native_reset,
 input font_clk,font_rst,font_request,input [31:0] font_lba,
 output reg font_busy,font_done,output reg [3:0] font_error,
 input [8:0] font_byte_address,output reg [7:0] font_byte_data
);
 reg [7:0] bytes[0:511];
 reg request_toggle,ack_toggle;reg [31:0] requested_lba;reg [3:0] error_held;
 (* ASYNC_REG="TRUE" *) reg [1:0] ack_sync,request_sync;
 reg request_seen,ack_seen,font_pending;reg [31:0] pending_lba;
 reg [1:0] owner,gap;reg image_seen;
 localparam integer BW=$clog2(IMAGE_BUDGET+1),TW=$clog2(TIMEOUT_CYCLES+1);
 reg [BW-1:0] image_served;reg [TW-1:0] timer;
 reg [9:0] received;
 assign image_valid=owner==1 && native_valid;
 assign image_end=owner==1 && native_end;
 assign image_data=native_data;
 assign image_initialized=native_initialized;
 always @(posedge font_clk)font_byte_data<=bytes[font_byte_address];
 always @(posedge sd_clk)if(owner==2 && native_valid && received<512 && !sd_rst)
  bytes[received[8:0]]<=native_data;
 always @(posedge font_clk or posedge font_rst)begin
  if(font_rst)begin request_toggle<=0;requested_lba<=0;ack_sync<=0;ack_seen<=0;font_busy<=0;font_done<=0;font_error<=0;end
  else begin
   font_done<=0;ack_sync<={ack_sync[0],ack_toggle};
   if(ack_sync[1]!=ack_seen)begin
    ack_seen<=ack_sync[1];font_busy<=0;font_done<=1;font_error<=error_held;
   end else if(font_request && !font_busy)begin
    requested_lba<=font_lba;request_toggle<=~request_toggle;font_busy<=1;font_error<=0;
   end
  end
 end
 always @(posedge sd_clk or posedge sd_rst)begin
  if(sd_rst)begin
   request_sync<=0;request_seen<=0;ack_toggle<=0;font_pending<=0;pending_lba<=0;error_held<=0;
   owner<=0;gap<=0;image_seen<=0;image_served<=0;timer<=0;received<=0;
   native_request<=0;native_lba<=0;native_count<=1;native_reset<=0;
  end else begin
   request_sync<={request_sync[0],request_toggle};native_reset<=0;
   if(!image_request)image_seen<=0;
   if(request_sync[1]!=request_seen && !font_pending)begin
    request_seen<=request_sync[1];font_pending<=1;pending_lba<=requested_lba;timer<=0;
   end else if(font_pending && timer<TIMEOUT_CYCLES-1)timer<=timer+1'b1;
   if(gap!=0)gap<=gap-1'b1;
   if(owner==2 && native_valid && received<513)received<=received+1'b1;
   if(owner!=0 && native_end)begin
    native_request<=0;owner<=0;gap<=3;
    if(owner==2)begin
     font_pending<=0;ack_toggle<=request_seen;
     error_held<=native_error!=0?native_error:((received==512 && !native_valid)||(received==511 && native_valid)?4'd0:4'hb);
    end
   end
   if(owner==0 && gap==0 && native_initialized && native_error==0 && !image_reset)begin
    if(image_request && !image_seen && (!font_pending || image_served<IMAGE_BUDGET))begin
     owner<=1;native_request<=1;native_lba<=image_lba;native_count<=image_count;
     image_seen<=1;if(image_served<IMAGE_BUDGET)image_served<=image_served+1'b1;
    end else if(font_pending && timer<TIMEOUT_CYCLES-1)begin
     owner<=2;native_request<=1;native_lba<=pending_lba;native_count<=1;received<=0;image_served<=0;
    end
   end
   // A font failure never exposes partial bytes as a completed glyph. A reset
   // requested by the existing image loader still owns native card recovery.
   if(font_pending && (timer==TIMEOUT_CYCLES-1 || native_error!=0 || image_reset))begin
    font_pending<=0;ack_toggle<=request_seen;
    error_held<=native_error!=0?native_error:4'he;
    if(owner==2)begin native_request<=0;owner<=0;gap<=3;native_reset<=1;end
   end
   if(image_reset)begin native_reset<=1;native_request<=0;owner<=0;gap<=3;image_seen<=image_request;end
   if(owner==1 && !native_initialized)begin native_request<=0;owner<=0;gap<=3;end
  end
 end
endmodule
