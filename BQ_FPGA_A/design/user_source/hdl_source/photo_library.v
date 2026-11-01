// three-slot cache, eight garden source files. KEY3 short previous, hold 0.8s dwell.
module photo_library #(parameter CLK_FREQ_HZ=100000000,parameter REMOTE_ENABLE=0)(
 input clk,rst,key_next,key_auto,key_period,display_commit_ack,write_finish_toggle,
 output [1:0] displayed_image,output reg [1:0] period_mode,
 output reg display_valid,output [3:0] state_code,output [2:0] debug_found_count,
 output [4:0] catalog_count,output debug_auto_play_en,output reg slide_paused,
 output reg [1:0] write_buf_idx,disp_buf_idx,
 output write_req,input write_req_ack,write_ready,output write_en,output [31:0] write_data,
 input ext_init,ext_valid,ext_end,input [7:0] ext_data,
 output ext_req,output [31:0] ext_addr,output [5:0] ext_count,output ext_reset,
 input remote_valid,input [2:0] remote_op,input [4:0] remote_value,
 output reg remote_done,output reg [7:0] remote_code,output reg [3:0] remote_id,
 input [3:0] catalog_index,input catalog_height,output [15:0] catalog_data,output catalog_ready,output [15:0] failed_files,output control_busy,output [3:0] current_media,
 output reg [43:0] native_widths,native_heights,output reg [15:0] bank_tags
);
wire next_press,auto_press;
key_press_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) kn(.clk(clk),.rst(rst),.button_in(key_next),.press_pulse(next_press));
key_press_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) ka(.clk(clk),.rst(rst),.button_in(key_auto),.press_pulse(auto_press));
reg [1:0] prev_sync;reg prev_stable,long_sent,prev_press,period_press;
localparam DB_BITS=$clog2(CLK_FREQ_HZ/50)<9?9:$clog2(CLK_FREQ_HZ/50);
localparam HOLD_BITS=$clog2(CLK_FREQ_HZ/5*4)<1?1:$clog2(CLK_FREQ_HZ/5*4);
reg [DB_BITS-1:0] prev_debounce;
reg [HOLD_BITS-1:0] hold_count;
reg prev_carry;
// Carry for the next low-byte increment is computed a cycle earlier.
// Every counter-clear also clears this prediction, including bounce/release.

always @(posedge clk or posedge rst)begin
 if(rst)begin prev_sync<=3;prev_stable<=1;long_sent<=0;prev_press<=0;period_press<=0;prev_debounce<=0;prev_carry<=0;hold_count<=0;end
 else begin
  prev_sync<={prev_sync[0],key_period};prev_press<=0;period_press<=0;
  if(prev_sync[1]==prev_stable)begin prev_debounce<=0;prev_carry<=0;end
  else if(prev_debounce==CLK_FREQ_HZ/50-1)begin
   prev_stable<=prev_sync[1];prev_debounce<=0;prev_carry<=0;
   if(prev_sync[1] && !long_sent)prev_press<=1;
  end else begin
   prev_debounce[7:0]<=prev_debounce[7:0]+1'b1;
   prev_debounce[DB_BITS-1:8]<=prev_debounce[DB_BITS-1:8]+prev_carry;
   prev_carry<=prev_debounce[7:0]==8'd254;
  end
  if(prev_stable)begin hold_count<=0;long_sent<=0;end
  else if(!long_sent)begin
   if(hold_count==CLK_FREQ_HZ/5*4-1)begin long_sent<=1;period_press<=1;end
   else hold_count<=hold_count+1'b1;
  end
 end
end
reg scan_start,load_start,kicked,load_busy,source_started,source_done,write_done,abort_load;
wire ready,scan_done,found;wire [31:0] cluster;wire [4:0] found_total;wire [3:0] source_state;
wire [23:0] pixel;
reg [3:0] current_id;reg [4:0] count;
reg remote_pending,remote_commit,remote_failed,remote_available,remote_range_bad;reg [3:0] remote_target;
wire remote_apply=REMOTE_ENABLE && remote_commit;
always @(posedge clk or posedge rst)begin
 if(rst)begin remote_pending<=0;remote_commit<=0;remote_failed<=0;remote_available<=0;remote_range_bad<=0;remote_target<=0;end
 else begin
  remote_pending<=remote_valid;
  remote_commit<=remote_pending;
  // Break the 16-way failed-file lookup away from navigation/timer enables.
  // The mailbox keeps the operation and value stable until remote_done.
  if(remote_pending)begin
   remote_failed<=failed[remote_target];
   remote_available<=scan_done && count!=0;
   remote_range_bad<=remote_op==0 && remote_value>=count;
  end
  if(remote_valid)remote_target<=remote_op==0?remote_value[3:0]:remote_op==1?successor(pending_next?pending_id:current_id):predecessor(pending_next?pending_id:current_id);
 end
end
reg [3:0] target_id;
wire [10:0] loaded_width,loaded_height;
reg [31:0] load_cluster;
reg [3:0] pending_id,load_id;reg [3:0] cache_valid;reg [15:0] failed;
reg [1:0] load_bank;reg pending_next,auto_play;
reg [$clog2(CLK_FREQ_HZ)-1:0] second_count;reg [$clog2(CLK_FREQ_HZ*10)-1:0] watchdog;reg [2:0] seconds;
reg [3:0] error;reg [2:0] finish_sync;
reg [1:0] recovery_attempt;
reg [$clog2(CLK_FREQ_HZ/10+1)-1:0] recovery_wait;
reg recovering;

wire finish_pulse=finish_sync[2]^finish_sync[1];
wire [2:0] period_seconds=period_mode==0?3'd1:period_mode==1?3'd3:3'd5;
wire tick=second_count==CLK_FREQ_HZ-1;
wire auto_due=auto_play && tick && seconds==period_seconds-1;
// Compare the ID directly to the last catalog index. Keep the increment
// parallel to the comparison instead of placing an adder before the bound.
function [3:0] successor;input [3:0] id;begin successor=(count==0 || {1'b0,id}>=count-5'd1)?0:id+1'b1;end endfunction
function [3:0] predecessor;input [3:0] id;begin predecessor=id==0?count-1'b1:id-1'b1;end endfunction
reg next_hit,previous_hit,nh_comb,ph_comb,hit;reg [1:0] hit_bank,victim;
always @(posedge clk or posedge rst)begin
 if(rst)begin next_hit<=0;previous_hit<=0;end
 else begin next_hit<=nh_comb;previous_hit<=ph_comb;end
end
reg [3:0] target_next;reg [1:0] plan_state;reg planned_hit,planned_failed;reg [1:0] planned_bank,planned_victim;integer k;
always @*begin
 nh_comb=0;ph_comb=0;
 for(k=0;k<3;k=k+1)begin
  if(cache_valid[k] && bank_tags[k*4+:4]==successor(current_id))nh_comb=1;
  if(cache_valid[k] && bank_tags[k*4+:4]==predecessor(current_id))ph_comb=1;
 end
 // The fourth slot looks two images ahead once both adjacent images are warm.
 target_next=!display_valid?4'd0:pending_next?pending_id:!next_hit?successor(current_id):!previous_hit?predecessor(current_id):current_id;
 hit=0;hit_bank=0;victim=disp_buf_idx==2?2'd0:disp_buf_idx+1'b1;
 for(k=0;k<3;k=k+1)if(k!=disp_buf_idx && (!cache_valid[k] ||
  (bank_tags[k*4+:4]!=successor(current_id) && bank_tags[k*4+:4]!=predecessor(current_id))))victim=k;
 for(k=0;k<3;k=k+1)if(cache_valid[k] && bank_tags[k*4+:4]==target_id)begin hit=1;hit_bank=k;end
end
assign current_media=current_id;assign failed_files=failed;assign control_busy=pending_next || !display_commit_ack || !display_valid;
assign displayed_image=disp_buf_idx;assign catalog_count=count;
assign debug_found_count=count>7?3'd7:count[2:0];assign debug_auto_play_en=auto_play;
assign state_code=error!=0?error:source_state;assign ext_reset=abort_load;assign write_data={pixel,8'd0};
fat16_bmp_read #(.PARALLEL_META(0),.LOAD_BY_INDEX(1),.CATALOG(8),.READ_TIMEOUT(CLK_FREQ_HZ*2)) source(
 .clk(clk),.rst(rst),.scan_start(scan_start),.scan_resume(kicked && !scan_done && !load_busy && !load_start),
 .load_start(load_start),.load_abort(abort_load),.sd_init_done(ext_init),
 .scan_start_sector(32'd0),.scan_max_sector(32'hffffffff),.load_sector(load_cluster),.scan_target_count(4'd8),
 .bmp_width(16'd1280),.bmp_height(16'd960),.ready(ready),.scan_done(scan_done),.scan_found_valid(found),
 .scan_found_sector(cluster),.scan_found_total(found_total),.state_code(source_state),
 .write_req(write_req),.write_req_ack(write_req_ack),.sd_sec_read(ext_req),.sd_sec_read_addr(ext_addr),.sd_read_count(ext_count),
 .sd_sec_read_data(ext_data),.sd_sec_read_data_valid(ext_valid),.sd_sec_read_end(ext_end),
 .output_ready(write_ready),.bmp_data_wr_en(write_en),.bmp_data(pixel),
 .native_widths(),.native_heights(),.query_index(catalog_index),.query_height(catalog_height),.query_data(catalog_data),.query_ready(catalog_ready),.loaded_width(loaded_width),.loaded_height(loaded_height));
always @(posedge clk or posedge rst)begin
 if(rst)begin
  remote_done<=0;remote_code<=0;remote_id<=0;scan_start<=0;load_start<=0;kicked<=0;load_busy<=0;source_started<=0;source_done<=0;write_done<=0;abort_load<=0;
  count<=0;load_cluster<=0;current_id<=0;pending_id<=0;load_id<=0;cache_valid<=0;failed<=0;
  load_bank<=0;pending_next<=0;auto_play<=0;slide_paused<=0;
  second_count<=0;seconds<=0;watchdog<=0;error<=0;recovery_attempt<=0;recovery_wait<=0;recovering<=0;finish_sync<=0;period_mode<=1;
  display_valid<=0;write_buf_idx<=0;disp_buf_idx<=0;bank_tags<=0;plan_state<=0;target_id<=0;planned_hit<=0;planned_failed<=0;planned_bank<=0;planned_victim<=0;
  native_widths<={4{11'd1280}};native_heights<={4{11'd960}};
 end else begin
  remote_done<=0;scan_start<=0;load_start<=0;abort_load<=0;finish_sync<={finish_sync[1:0],write_finish_toggle};
  if(found)count<=found_total;
  if(!ext_init)begin
   kicked<=0;load_busy<=0;count<=0;plan_state<=0;
   if(load_busy)cache_valid[load_bank]<=0;
   // A card remount does not change complete SDRAM images or their ownership.
  end
  else if(!kicked && ready)begin scan_start<=1;kicked<=1;end
  if(remote_apply)begin
   remote_done<=1;remote_code<=0;remote_id<=remote_op<=2?remote_target:remote_value[3:0];
   if(!ext_init || !remote_available)remote_code<=8;
   else case(remote_op)
    0,1,2:begin
     if(remote_range_bad)remote_code<=2;
     
     else begin
      pending_next<=1;
      pending_id<=remote_target;failed[remote_target]<=0;recovery_attempt<=0;recovering<=0;error<=0;
      if(ready && source_state>=4'hb)begin abort_load<=1;kicked<=0;plan_state<=0;end
      auto_play<=0;slide_paused<=0;second_count<=0;seconds<=0;remote_code<=1;
     end
    end
    3:begin auto_play<=remote_value[0];slide_paused<=!remote_value[0];end
    4:begin period_mode<=remote_value[1:0];second_count<=0;seconds<=0;end
    5:begin auto_play<=0;slide_paused<=0;second_count<=0;seconds<=0;end
    default:remote_code<=3;
   endcase
  end else if(next_press || prev_press)begin
   pending_next<=1;pending_id<=prev_press?predecessor(pending_next?pending_id:current_id):successor(pending_next?pending_id:current_id);
   auto_play<=0;slide_paused<=0;second_count<=0;seconds<=0;failed<=0;recovery_attempt<=0;recovering<=0;error<=0;
   if(ready && source_state>=4'hb)begin abort_load<=1;kicked<=0;plan_state<=0;end
  end else if(auto_press)begin auto_play<=~auto_play;slide_paused<=auto_play;end
  if(period_press && !remote_apply)begin period_mode<=period_mode==2?0:period_mode+1'b1;second_count<=0;seconds<=0;end
  if(auto_play && display_valid && display_commit_ack && !next_press && !prev_press && !auto_press && !period_press && !remote_apply)begin
   if(tick)begin second_count<=0;seconds<=auto_due?0:seconds+1'b1;end else second_count<=second_count+1'b1;
   if(auto_due && !pending_next)begin pending_next<=1;pending_id<=successor(current_id);end
  end
  if(!display_commit_ack)begin second_count<=0;seconds<=0;end
  if(remote_apply || next_press || prev_press || auto_due || !display_commit_ack)plan_state<=0;
  if(load_busy)begin
   watchdog<=watchdog+1'b1;
   if(!ready)source_started<=1;
   if(source_started && ready)source_done<=1;
   if(finish_pulse)write_done<=1;
   if((source_started && ready && source_state>=4'hb) || watchdog>=CLK_FREQ_HZ*10-1)begin
    load_busy<=0;failed[load_id]<=1;cache_valid[load_bank]<=0;error<=source_state>=4'hb ? source_state:4'he;
    // Recover a transient FAT/transport failure, with two bounded attempts.
    // Keep a permanent bad file marked until the user explicitly retries it.
    if(recovery_attempt<2)begin recovering<=1;recovery_wait<=0;end
   end else if(source_done && write_done)begin
    load_busy<=0;cache_valid[load_bank]<=1;bank_tags[load_bank*4+:4]<=load_id;
    native_widths[load_bank*11+:11]<=loaded_width;
    native_heights[load_bank*11+:11]<=loaded_height;error<=0;failed[load_id]<=0;recovery_attempt<=0;
   end
  end
  if(recovering)begin
   if(recovery_wait==CLK_FREQ_HZ/10-1)begin
    recovery_wait<=0;recovering<=0;recovery_attempt<=recovery_attempt+1'b1;
    failed[load_id]<=0;abort_load<=1;kicked<=0;plan_state<=0;
   end else recovery_wait<=recovery_wait+1'b1;
  end
  // Cached navigation must not wait behind an unrelated background BMP read.
  // The loading slot is invalid until the entire source and SDRAM write finish.
  // Only cached hits may commit while loading; transition acknowledgement still
  // protects both displayed banks, and no second writer can be started here.
  if(!recovering && ext_init && scan_done && count!=0 && display_commit_ack && !next_press && !prev_press && !auto_due && !remote_apply)begin
   if(plan_state==0)plan_state<=3;
   else if(plan_state==3)begin target_id<=target_next;plan_state<=1;end
   else if(plan_state==1)begin plan_state<=2;planned_hit<=hit;planned_failed<=failed[target_id];planned_bank<=hit_bank;planned_victim<=victim;end
   else begin
   plan_state<=0;
   if(planned_hit && (!display_valid || pending_next))begin
    disp_buf_idx<=planned_bank;current_id<=target_id;display_valid<=1;pending_next<=0;
   end else if(planned_failed && pending_next)begin
    pending_next<=0;error<=4'hd;
   end else if(!load_busy && ready && !planned_hit && !planned_failed)begin
    load_id<=target_id;load_cluster<={28'd0,target_id};load_bank<=display_valid?planned_victim:2'd0;
    write_buf_idx<=display_valid?planned_victim:2'd0;cache_valid[display_valid?planned_victim:2'd0]<=0;
    load_start<=1;load_busy<=1;source_started<=0;source_done<=0;write_done<=0;watchdog<=0;
   end
   end
  end
  // A just-filled slot changes the hit lookup. Discard an older miss plan so
  // it cannot launch a duplicate read on the cycle after load_busy clears.
  if(load_busy && source_done && write_done)plan_state<=0;
 end
end
endmodule
