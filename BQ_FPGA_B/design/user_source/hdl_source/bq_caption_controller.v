// B-only controller. UART acceptance is independent of TF reads and A latency.
// Common service, builder and both cache endpoints report actual frame commits.
module bq_caption_controller #(
 parameter [31:0] FONT_BASE_LBA=0,
 parameter integer POLL_CYCLES=50000,RETRY_CYCLES=500000,AUDIT_CYCLES=50000000,MAX_JOB_CYCLES=400000000
)(
 input clk,rst,valid,input [47:0] command,output done,output [39:0] response,
 output [5:0] text_address,input [7:0] text_data,
 input remote_online,output remote_valid,output [47:0] remote_command,
 input remote_ready,remote_done,input [39:0] remote_response,
 output sector_request,output [31:0] sector_lba,input sector_done,input [3:0] sector_error,
 output [8:0] byte_address,input [7:0] byte_data,
 input video_clk,video_rst,frame_start,input [9:0] row_address,output [31:0] row_bits,
 output [5:0] visible_count,output [15:0] visible_epoch,display_serial,output [8:0] visible_settings
);
 wire accepted,updating,enabled;wire [1:0] motion;wire [5:0] speed,char_count;
 wire [15:0] desired_epoch,local_epoch,remote_epoch,character;wire [4:0] char_address;
 wire [5:0] actual_count;wire [8:0] local_settings,remote_settings;wire remote_settings_known;
 wire [7:0] render_error;wire builder_busy;
 wire font_start,font_busy,font_done,word_valid,word_ready;wire [15:0] font_character;
 wire [3:0] font_error;wire [4:0] row_index;wire [31:0] row_word;
 wire local_valid,local_done;wire [2:0] local_operation;wire [31:0] local_value,local_result;wire [7:0] local_code;
 bq_caption_service service(.clk(clk),.rst(rst),.valid(valid),.command(command),.done(done),.response(response),
  .text_address(text_address),.text_data(text_data),.accepted(accepted),.updating(updating),.desired_epoch(desired_epoch),
  .char_count(char_count),.char_address(char_address),.character(character),.local_epoch(local_epoch),.remote_epoch(remote_epoch),
  .remote_online(remote_online),.render_error(render_error),.local_count(actual_count),.local_settings(local_settings),
  .remote_settings(remote_settings),.remote_settings_known(remote_settings_known),.enabled(enabled),.motion(motion),.speed(speed));
 bq_caption_manager #(.POLL_CYCLES(POLL_CYCLES),.RETRY_CYCLES(RETRY_CYCLES),.AUDIT_CYCLES(AUDIT_CYCLES),.MAX_JOB_CYCLES(MAX_JOB_CYCLES)) manager(
  .clk(clk),.rst(rst),.desired_epoch(desired_epoch),.char_count(char_count),.text_updating(updating),.desired_settings({speed,motion,enabled}),.remote_online(remote_online),
  .char_address(char_address),.character(character),.font_start(font_start),.font_character(font_character),.font_busy(font_busy),.font_done(font_done),.font_error(font_error),
  .word_valid(word_valid),.row_index(row_index),.row_word(row_word),.word_ready(word_ready),
  .local_valid(local_valid),.local_operation(local_operation),.local_value(local_value),.local_done(local_done),.local_code(local_code),.local_result(local_result),
  .local_epoch(local_epoch),.local_settings(local_settings),.remote_valid(remote_valid),.remote_command(remote_command),
  .remote_ready(remote_ready),.remote_done(remote_done),.remote_response(remote_response),.remote_epoch(remote_epoch),
  .remote_settings(remote_settings),.remote_settings_known(remote_settings_known),.render_error(render_error),.builder_busy(builder_busy));
 bq_font_reader #(.FONT_BASE_LBA(FONT_BASE_LBA)) reader(.clk(clk),.rst(rst),.start(font_start),.character(font_character),
  .busy(font_busy),.done(font_done),.error(font_error),.sector_request(sector_request),.sector_lba(sector_lba),
  .sector_done(sector_done),.sector_error(sector_error),.byte_address(byte_address),.byte_data(byte_data),
  .word_valid(word_valid),.row_index(row_index),.row_word(row_word),.word_ready(word_ready));
 bq_caption_endpoint endpoint(.clk(clk),.rst(rst),.valid(local_valid),.operation(local_operation),.value(local_value),
  .done(local_done),.code(local_code),.result(local_result),.video_clk(video_clk),.video_rst(video_rst),.frame_start(frame_start),
  .row_address(row_address),.row_bits(row_bits),.visible_count(visible_count),.visible_epoch(visible_epoch),.applied_epoch(local_epoch),
  .applied_count(actual_count),.display_serial(display_serial),.visible_settings(visible_settings),.applied_settings(local_settings));
endmodule
