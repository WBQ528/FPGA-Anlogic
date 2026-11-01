// Runtime itinerary editor, UTF-8 serializer and double-buffered QR publication.
// Edit operations: 1 add POI(1..4), 2 remove row(0..3), 3 up, 4 down,
// 5 clear, 6 generate/reuse. Invalid edits leave the revision unchanged.
module b_visit_list(
 input clk,rst,edit_valid,input [2:0] edit_op,input [3:0] edit_value,
 output reg edit_done,output reg [7:0] edit_code,
 output reg [11:0] order,output reg [2:0] count,output reg [31:0] revision,
 output generating,output qr_ready,
 input video_clk,video_rst,frame_request,
 output [11:0] video_order,output [2:0] video_count,
 output [31:0] video_revision,output video_qr_valid,
 input [10:0] qr_read_address,output reg qr_pixel
);
reg [11:0] next_order;reg [2:0] next_count;reg [7:0] code;
reg duplicate,change;reg [2:0] swap;integer i;
always @*begin
 next_order=order;next_count=count;code=0;duplicate=0;swap=0;change=0;
 for(i=0;i<4;i=i+1)if(i<count && order[i*3+:3]==edit_value)duplicate=1;
 case(edit_op)
  1:if(edit_value<1 || edit_value>4)code=2;
    else if(!duplicate && count<4)begin
     case(count)0:next_order[2:0]=edit_value[2:0];1:next_order[5:3]=edit_value[2:0];2:next_order[8:6]=edit_value[2:0];3:next_order[11:9]=edit_value[2:0];endcase
     next_count=count+1'b1;change=1;
    end
  2:if(edit_value>=count)code=2;
    else begin
     for(i=0;i<3;i=i+1)if(i>=edit_value)next_order[i*3+:3]=order[(i+1)*3+:3];
     next_order[11:9]=0;next_count=count-1'b1;change=1;
    end
  3:if(edit_value>=count || edit_value==0)code=2;
    else begin
     case(edit_value[1:0])1:next_order[5:0]={order[2:0],order[5:3]};2:next_order[8:3]={order[5:3],order[8:6]};3:next_order[11:6]={order[8:6],order[11:9]};endcase
     change=1;
    end
  4:if(edit_value>=count || edit_value+4'd1>=count)code=2;
    else begin
     case(edit_value[1:0])0:next_order[5:0]={order[2:0],order[5:3]};1:next_order[8:3]={order[5:3],order[8:6]};2:next_order[11:6]={order[8:6],order[11:9]};endcase
     change=1;
    end
  5:begin next_order=0;next_count=0;change=count!=0;end
  6:if(count==0)code=2;
  default:code=3;
 endcase
end
wire changed=edit_valid && change;
reg start,work_bank,ready;reg [31:0] work_revision;reg [11:0] work_order;reg [2:0] work_count;
wire busy,done;wire [1:0] error;wire [6:0] byte_index;wire [7:0] byte_data,payload_length;
wire write;wire [5:0] wx,wy;wire bit_data;
wire [48:0] requested={revision,count,order,ready,work_bank};
wire [48:0] active,returned;
wire commit_ack,idle;
frame_bundle_commit #(.WIDTH(49)) publish(.source_clk(clk),.source_rst(rst),.dest_clk(video_clk),.dest_rst(video_rst),
 .requested(requested),.frame_req(frame_request),.commit_ack(commit_ack),.transfer_idle(idle),.active(active),.source_active(returned));
assign video_order=active[13:2];assign video_count=active[16:14];assign video_revision=active[48:17];
assign video_qr_valid=active[1] && active[16:14]!=0;
assign qr_ready=ready;assign generating=busy || start || (count!=0 && !ready);
always @(posedge clk or posedge rst)begin
 if(rst)begin order<=0;count<=0;revision<=0;edit_done<=0;edit_code<=0;start<=0;work_bank<=0;ready<=0;work_revision<=0;work_order<=0;work_count<=0;end
 else begin
  edit_done<=edit_valid;start<=0;
  if(edit_valid)edit_code<=code;
  if(changed)begin order<=next_order;count<=next_count;revision<=revision+1'b1;ready<=0;end
  // Wait until the invalid/current text snapshot is displayed. This guarantees
  // that the inactive bank is neither displayed nor an in-flight publication.
  if(!busy && !done && !start && !ready && count!=0 && !edit_valid && idle && commit_ack &&
     returned[48:17]==revision && !returned[1])begin
   work_order<=order;work_count<=count;work_revision<=revision;
   work_bank<=~returned[0];start<=1;
  end
  if(done && error==0 && work_revision==revision && !edit_valid)ready<=1;
 end
end
b_visit_utf8 text(.order(work_order),.count(work_count),.index(byte_index),.data(byte_data),.length(payload_length));
b_qr_encoder encoder(.clk(clk),.rst(rst),.start(start),.payload_length(payload_length),
 .payload_index(byte_index),.payload_byte(byte_data),.busy(busy),.done(done),.error(error),
 .module_write(write),.module_x(wx),.module_y(wy),.module_bit(bit_data),.chosen_mask());
wire [10:0] write_address=({5'd0,wy}<<5)+({5'd0,wy}<<2)+{5'd0,wy}+{5'd0,wx};
reg modules[0:4095];
always @(posedge clk)if(write)modules[{work_bank,write_address}]<=bit_data;
always @(posedge video_clk)qr_pixel<=modules[{active[0],qr_read_address}];
endmodule
