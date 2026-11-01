// B master: local rendering first, then low-priority A synchronization.
// Only the newest accepted generation is scheduled. Config changes can pass a
// glyph stream at word boundaries; foreground RPCs retain priority outside.
module bq_caption_manager #(
 parameter integer POLL_CYCLES=50000,
 parameter integer RETRY_CYCLES=500000,
 parameter integer AUDIT_CYCLES=50000000,
 parameter integer MAX_JOB_CYCLES=400000000
)(
 input clk,rst,input [15:0] desired_epoch,input [5:0] char_count,
 input text_updating,input [8:0] desired_settings,input remote_online,
 output [4:0] char_address,input [15:0] character,
 output font_start,output [15:0] font_character,input font_busy,font_done,
 input [3:0] font_error,input word_valid,input [4:0] row_index,
 input [31:0] row_word,output word_ready,
 output reg local_valid,output reg [2:0] local_operation,output reg [31:0] local_value,
 input local_done,input [7:0] local_code,input [31:0] local_result,
 input [15:0] local_epoch,input [8:0] local_settings,
 output reg remote_valid,output reg [47:0] remote_command,input remote_ready,remote_done,
 input [39:0] remote_response,
 output reg [15:0] remote_epoch,output reg [8:0] remote_settings,
 output reg remote_settings_known,output reg [7:0] render_error,
 output builder_busy
);
 localparam integer RW=$clog2(RETRY_CYCLES+1),PW=$clog2(POLL_CYCLES+1),
                    CW=$clog2(AUDIT_CYCLES+1);
 reg builder_start,job_remote;reg [15:0] job_epoch,seen_epoch,failed_local,failed_remote;
 reg [5:0] job_count;wire builder_done;wire [7:0] builder_error;wire [15:0] builder_applied;
 wire builder_request;wire [2:0] builder_operation;wire [31:0] builder_value;
 reg builder_ready,builder_response_done;reg [7:0] builder_code;reg [31:0] builder_result;
 reg [1:0] local_owner;reg [2:0] remote_owner;
 reg [8:0] local_sent,remote_sent;reg local_cfg_wait,remote_cfg_poll;
 reg [PW-1:0] local_cfg_age,remote_cfg_age;
 reg [RW-1:0] local_retry,remote_retry;
 reg [CW-1:0] audit_age,local_cfg_watch;
 reg was_online,remote_verified;reg [1:0] remote_failures;
 wire cancel_job=text_updating || job_epoch!=desired_epoch || (job_remote && !remote_online);
 wire local_cfg_needed=local_settings!=desired_settings &&
                       (!local_cfg_wait || local_sent!=desired_settings);
 wire remote_cfg_needed=!remote_settings_known || remote_settings!=desired_settings;
 bq_caption_builder #(.POLL_CYCLES(POLL_CYCLES),.MAX_CYCLES(MAX_JOB_CYCLES)) builder(
  .clk(clk),.rst(rst),.start(builder_start),.cancel(cancel_job),.epoch(job_epoch),.count(job_count),
  .busy(builder_busy),.done(builder_done),.error(builder_error),.char_address(char_address),.character(character),
  .font_start(font_start),.font_character(font_character),.font_busy(font_busy),.font_done(font_done),
  .font_error(font_error),.word_valid(word_valid),.row_index(row_index),.row_word(row_word),.word_ready(word_ready),
  .request(builder_request),.request_ready(builder_ready),.operation(builder_operation),.value(builder_value),
  .response_done(builder_response_done),.response_code(builder_code),.response_value(builder_result),.applied_epoch(builder_applied));
 always @(posedge clk or posedge rst)begin
  if(rst)begin
   builder_start<=0;job_remote<=0;job_epoch<=0;job_count<=0;seen_epoch<=0;failed_local<=0;failed_remote<=0;
   builder_ready<=0;builder_response_done<=0;builder_code<=0;builder_result<=0;
   local_valid<=0;local_operation<=0;local_value<=0;local_owner<=0;
   remote_valid<=0;remote_command<=0;remote_owner<=0;
   remote_epoch<=0;remote_settings<=0;remote_settings_known<=0;render_error<=0;
   local_sent<=0;remote_sent<=0;local_cfg_wait<=0;remote_cfg_poll<=0;
   local_cfg_age<=0;remote_cfg_age<=0;local_retry<=0;remote_retry<=0;
   audit_age<=0;local_cfg_watch<=0;was_online<=0;remote_verified<=0;remote_failures<=0;
  end else begin
   builder_start<=0;builder_ready<=0;builder_response_done<=0;local_valid<=0;
   was_online<=remote_online;
   if(local_cfg_age!=0)local_cfg_age<=local_cfg_age-1'b1;
   if(remote_cfg_age!=0)remote_cfg_age<=remote_cfg_age-1'b1;
   if(local_retry!=0)local_retry<=local_retry-1'b1;
   if(remote_retry!=0)remote_retry<=remote_retry-1'b1;
   if(remote_online && audit_age<AUDIT_CYCLES)audit_age<=audit_age+1'b1;
   if(local_cfg_wait)begin
    if(local_settings==local_sent || local_cfg_watch==AUDIT_CYCLES)begin local_cfg_wait<=0;local_cfg_watch<=0;end
    else local_cfg_watch<=local_cfg_watch+1'b1;
   end
   if(remote_online && !was_online)begin failed_remote<=0;remote_failures<=0;remote_cfg_age<=0;end
   // Ordinary configuration has priority at the next local glyph-word slot.
   if(local_owner==0)begin
    if(local_cfg_needed && local_cfg_age==0)begin
     local_owner<=2;local_valid<=1;local_operation<=4;local_value<={23'd0,desired_settings};local_sent<=desired_settings;
    end else if(builder_request && !job_remote)begin
     local_owner<=1;local_valid<=1;local_operation<=builder_operation;local_value<=builder_value;builder_ready<=1;
    end
   end else if(local_done)begin
    local_owner<=0;
    if(local_owner==1)begin builder_response_done<=1;builder_code<=local_code;builder_result<=local_result;end
    else begin
     local_cfg_age<=POLL_CYCLES-1;
     if(local_code==0 || local_code==1)begin local_cfg_wait<=1;local_cfg_watch<=0;end
    end
   end
   // Remote valid is held until the low-priority RPC slot accepts it.
   if(remote_valid && remote_ready)begin
    remote_valid<=0;
    if(remote_owner==1)builder_ready<=1;
   end
   if(remote_owner==0)begin
    if(builder_request && job_remote && !remote_online)begin
     // Complete an unissued request locally when A has gone away. This paired
     // ready/done sequence allows the builder to drain and release its font IO.
     builder_ready<=1;remote_owner<=6;
    end else if(remote_online)begin
     if(remote_cfg_age==0 && (remote_cfg_needed || remote_cfg_poll))begin
      remote_valid<=1;
      if(remote_cfg_poll)begin remote_owner<=3;remote_command<={8'h50,8'd5,32'd0};end
      else begin remote_owner<=2;remote_command<={8'h50,8'd4,23'd0,desired_settings};remote_sent<=desired_settings;end
     end else if(audit_age==AUDIT_CYCLES)begin
      remote_owner<=4;remote_valid<=1;remote_command<={8'h50,8'd3,32'd0};audit_age<=0;
     end else if(builder_request && job_remote)begin
      remote_owner<=1;remote_valid<=1;remote_command<={8'h50,5'd0,builder_operation,builder_value};
     end
    end
   end else if(remote_owner==6)begin
    builder_response_done<=1;builder_code<=10;builder_result<=0;remote_owner<=7;
   end else if(remote_owner==7)remote_owner<=0;
   else if(remote_done)begin
    remote_owner<=0;
    case(remote_owner)
     1:begin builder_response_done<=1;builder_code<=remote_response[39:32];builder_result<=remote_response[31:0];end
     2:begin
      remote_cfg_age<=POLL_CYCLES-1;
      if(remote_response[39:32]<=1)remote_cfg_poll<=1;
     end
     3:begin
      remote_cfg_age<=POLL_CYCLES-1;
      if(remote_response[39:32]==0 && !remote_response[9])begin
       remote_settings<=remote_response[8:0];remote_settings_known<=1;remote_cfg_poll<=0;
      end
     end
     4:if(remote_response[39:32]==0)begin
      // An equal numeric epoch after a B restart is not proof that A has this
      // text. Only our completed current-generation write establishes that.
      remote_epoch<=remote_verified?remote_response[31:16]:16'd0;remote_settings_known<=0;
      if(remote_response[31:16]!=desired_epoch)remote_verified<=0;
     end
    endcase
   end
   // Start B first. A's stale/offline state never prevents a local generation.
   if(!builder_busy && !builder_start && !builder_done && !text_updating && desired_epoch!=0)begin
    if(local_epoch!=desired_epoch && failed_local!=desired_epoch && local_retry==0)begin
     job_remote<=0;job_epoch<=desired_epoch;job_count<=char_count;builder_start<=1;
    end else if(local_epoch==desired_epoch && remote_online && (!remote_verified || remote_epoch!=desired_epoch) &&
                failed_remote!=desired_epoch && remote_retry==0)begin
     job_remote<=1;job_epoch<=desired_epoch;job_count<=char_count;builder_start<=1;
    end
   end
   if(builder_done && job_epoch==desired_epoch && !text_updating)begin
    if(builder_error==0)begin
     if(job_remote)begin remote_epoch<=builder_applied;remote_verified<=1;remote_failures<=0;end
     render_error<=0;
    end else if(job_remote)begin
     remote_retry<=RETRY_CYCLES-1;
     if(builder_error>=12)begin failed_remote<=job_epoch;render_error<=builder_error;end
     else if(builder_error==2 || builder_error==3 || builder_error==4)begin
      if(remote_failures==2)begin failed_remote<=job_epoch;render_error<=builder_error;end
      else remote_failures<=remote_failures+1'b1;
     end
    end else begin
     local_retry<=RETRY_CYCLES-1;
     if(builder_error!=8 && builder_error!=10)begin failed_local<=job_epoch;render_error<=builder_error;end
    end
   end
   // Invalidation wins over a late response in the same cycle.
   if(seen_epoch!=desired_epoch)begin
    seen_epoch<=desired_epoch;failed_local<=0;failed_remote<=0;render_error<=0;
    local_retry<=0;remote_retry<=0;remote_failures<=0;remote_verified<=0;remote_epoch<=0;
   end
   if(!remote_online)begin
    remote_epoch<=0;remote_verified<=0;remote_settings_known<=0;remote_cfg_poll<=0;audit_age<=0;remote_retry<=0;
   end
  end
 end
endmodule
