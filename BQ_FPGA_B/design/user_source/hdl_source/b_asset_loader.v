// B cache: map + twelve ordinary garden images, ordered by manifest.
// Bank 0 permanently pins the map. Three photo banks are only overwritten
// after video-domain ownership has returned. Pixel units are RGB888; SDRAM
// writes are packed later. Source complete != SDRAM write complete.
module b_asset_loader #(parameter CLK_HZ=100000000)(
 input clk,rst,input [3:0] desired_asset,input display_ack,
 input [3:0] pinned_valid,output [3:0] loading_asset,output reg asset_complete,
 input [1:0] displayed_bank,input write_finish_toggle,
 output reg map_valid,output reg photo_valid,output reg [1:0] photo_bank,
 output reg [3:0] photo_asset,output reg [3:0] error,
 output reg [10:0] photo_width,photo_height,
 output [3:0] cache_valid_out,output [15:0] cache_tags,
 output reg [1:0] write_bank,output write_req,input write_req_ack,write_ready,
 output write_en,output [23:0] pixel,
 input ext_init,ext_valid,ext_end,input [7:0] ext_data,
 output ext_req,output [31:0] ext_addr,output [4:0] ext_count,output ext_reset
);
reg scan_start,load_start,kicked,loading,started,source_done,write_done,abort_load;
reg [3:0] count,cache_valid;reg [10:0] widths[0:3],heights[0:3];reg [15:0] tags;
reg [3:0] load_id;reg [31:0] watchdog;reg [2:0] finish_sync;
reg [1:0] retry_count;reg [26:0] retry_wait;reg [3:0] last_desired;
wire ready,scan_done,found;wire [4:0] found_count;wire [3:0] state;
// Local mount enable removes a long transport-to-FAT register-enable path.
// Cache publication still checks ext_init directly on a transport failure.
reg source_init;
always @(posedge clk or posedge rst)if(rst)source_init<=0;else source_init<=ext_init;
wire [10:0] loaded_w,loaded_h;
reg hit;reg [1:0] hit_bank,victim;integer i;
reg load_expired,plan_valid,plan_idle,plan_hit;reg [1:0] plan_bank,plan_victim;reg [3:0] plan_wanted;
wire [3:0] wanted=map_valid?desired_asset:4'd0;
function [3:0] garden;input [3:0] n;begin
 if(n<=4)garden=n;else if(n<=6)garden=1;else if(n<=8)garden=2;else if(n<=10)garden=3;else garden=4;
end endfunction
wire [3:0] group_id=garden(wanted);
wire [3:0] sibling1=(group_id<<1)+3,sibling2=(group_id<<1)+4;
reg [2:0] resident;reg [3:0] fetch_id,plan_fetch;reg victim_valid,plan_space;
always @(posedge clk or posedge rst)
 if(rst)begin load_expired<=0;plan_valid<=0;plan_idle<=0;plan_hit<=0;plan_bank<=0;plan_victim<=1;plan_wanted<=0;plan_fetch<=0;plan_space<=0;end
 else begin
  load_expired<=loading && watchdog>=CLK_HZ*12-1;
  plan_valid<=!load_start;
  plan_idle<=!loading && !load_start && ready;
  plan_hit<=hit;plan_bank<=hit_bank;plan_victim<=victim;plan_wanted<=wanted;
  plan_fetch<=fetch_id;plan_space<=victim_valid;
 end
assign loading_asset=load_id;
assign cache_valid_out=cache_valid;assign cache_tags=tags;assign ext_reset=abort_load;
always @*begin
 hit=0;hit_bank=0;resident=0;
 for(i=1;i<4;i=i+1)if(cache_valid[i])begin
  if(tags[i*4+:4]==group_id)resident[0]=1;
  if(tags[i*4+:4]==sibling1)resident[1]=1;
  if(tags[i*4+:4]==sibling2)resident[2]=1;
 end
 for(i=0;i<4;i=i+1)if(cache_valid[i] && tags[i*4+:4]==wanted)begin hit=1;hit_bank=i;end
 fetch_id=wanted;
 if(hit && wanted!=0)begin
  if(!resident[0])fetch_id=group_id;
  else if(!resident[1])fetch_id=sibling1;
  else if(!resident[2])fetch_id=sibling2;
  else fetch_id=0;
  // Warm every permanent map thumbnail before speculative garden siblings.
  // A selected uncached picture still has priority; no startup wait gate.
  if(!pinned_valid[3])fetch_id=4;
  if(!pinned_valid[2])fetch_id=3;
  if(!pinned_valid[1])fetch_id=2;
  if(!pinned_valid[0])fetch_id=1;
 end
 // Deterministic victim excludes map and the displayed/pending photo.
 victim=1;victim_valid=0;
 for(i=1;i<4;i=i+1)if(i!=displayed_bank && i!=photo_bank &&
  (!hit || !cache_valid[i] || (tags[i*4+:4]!=group_id &&
   tags[i*4+:4]!=sibling1 && tags[i*4+:4]!=sibling2) || pinned_valid!=15))begin victim=i;victim_valid=1;end
 for(i=1;i<4;i=i+1)if(i!=displayed_bank && i!=photo_bank && !cache_valid[i])begin victim=i;victim_valid=1;end
end
fat16_bmp_read #(.PARALLEL_META(0),.LOAD_BY_INDEX(1),.CATALOG(16),.READ_TIMEOUT(CLK_HZ*2)) source(
 .clk(clk),.rst(rst),.scan_start(scan_start),.scan_resume(kicked && !scan_done && !loading && !load_start),
 .load_start(load_start),.load_abort(abort_load),.sd_init_done(source_init),
 .scan_start_sector(32'd0),.scan_max_sector(32'hffffffff),.load_sector({28'd0,load_id}),.scan_target_count(5'd13),
 .bmp_width(16'd1280),.bmp_height(16'd720),.ready(ready),.scan_done(scan_done),.scan_found_valid(found),
 .scan_found_sector(),.scan_found_total(found_count),.state_code(state),.write_req(write_req),.write_req_ack(write_req_ack),
 .sd_sec_read(ext_req),.sd_sec_read_addr(ext_addr),.sd_read_count(ext_count),.sd_sec_read_data(ext_data),.sd_sec_read_data_valid(ext_valid),.sd_sec_read_end(ext_end),
 .output_ready(write_ready),.bmp_data_wr_en(write_en),.bmp_data(pixel),.native_widths(),.native_heights(),
 .query_index(4'd0),.query_height(1'b0),.query_data(),.query_ready(),.loaded_width(loaded_w),.loaded_height(loaded_h));
always @(posedge clk or posedge rst)begin
 if(rst)begin
  asset_complete<=0;scan_start<=0;load_start<=0;kicked<=0;loading<=0;started<=0;source_done<=0;write_done<=0;abort_load<=0;
  count<=0;cache_valid<=0;tags<=0;load_id<=0;watchdog<=0;finish_sync<=0;
  map_valid<=0;photo_valid<=0;photo_bank<=0;photo_asset<=0;error<=0;write_bank<=0;
  retry_count<=0;retry_wait<=0;last_desired<=0;photo_width<=1280;photo_height<=720;
 end else begin
  asset_complete<=0;scan_start<=0;load_start<=0;abort_load<=0;finish_sync<={finish_sync[1:0],write_finish_toggle};
  last_desired<=desired_asset;
  if(desired_asset!=last_desired)begin retry_count<=0;retry_wait<=0;end
  else if(error!=0 && !loading && retry_count<2)begin
   if(retry_wait==CLK_HZ-1)begin
    // A failed FAT reader remains in FAIL until reset. Bound automatic retry
    // to two remounts per requested asset, with a one-second recovery interval.
    retry_count<=retry_count+1'b1;retry_wait<=0;
    abort_load<=1;kicked<=0;error<=0;
   end else retry_wait<=retry_wait+1'b1;
  end else retry_wait<=0;
  if(found)count<=found_count;
  // Mount/catalog errors used to remain invisible outside the FAT reader,
  // leaving an empty photo card indefinitely without a diagnostic.
  if(kicked && !abort_load && scan_done && !loading && retry_wait!=CLK_HZ-1 && state>=4'hb)error<=state;
  else if(kicked && !abort_load && scan_done && !loading && retry_wait!=CLK_HZ-1 && found_count==0)error<=4'hf;
  if(!ext_init)begin
   kicked<=0;loading<=0;count<=0;
   // A transport fault cannot corrupt already-complete SDRAM banks.
   if(loading)cache_valid[write_bank]<=0;
  end
  else if(!kicked && ready)begin scan_start<=1;kicked<=1;end
  if(loading && ext_init)begin
   watchdog<=watchdog+1'b1;
   if(!ready)started<=1;
   if(started && ready)source_done<=1;
   if(finish_sync[2]!=finish_sync[1])write_done<=1;
   if((started && ready && state>=4'hb) || load_expired)begin
    loading<=0;error<=state>=4'hb ?state:4'he;cache_valid[write_bank]<=0;
    if(load_expired)abort_load<=1;
   end else if(source_done && write_done)begin
    asset_complete<=1;loading<=0;cache_valid[write_bank]<=1;tags[write_bank*4+:4]<=load_id;error<=0;
    widths[write_bank]<=loaded_w;heights[write_bank]<=loaded_h;
    if(load_id==0)map_valid<=1;
   end
  end else if(ext_init && scan_done && ready && display_ack && plan_idle && plan_valid && plan_wanted==wanted)begin
   if((!plan_hit || plan_fetch!=0) && plan_fetch<found_count && error==0 && (plan_fetch==0 || plan_space) &&
    (!plan_hit || (photo_valid && photo_asset==wanted)))begin
    load_id<=plan_fetch;write_bank<=plan_fetch==0?2'd0:plan_victim;
    cache_valid[plan_fetch==0?2'd0:plan_victim]<=0;load_start<=1;loading<=1;
    started<=0;source_done<=0;write_done<=0;watchdog<=0;
   end
  end
  // A hit need not wait for an unrelated speculative read. Publication is
  // atomic; the old photograph stays valid through loading and cover.
  if(ext_init && display_ack && plan_valid && plan_wanted==wanted && plan_hit && wanted!=0 &&
     cache_valid[plan_bank] && tags[plan_bank*4+:4]==wanted)begin
   photo_bank<=plan_bank;photo_asset<=wanted;photo_valid<=1;photo_width<=widths[plan_bank];photo_height<=heights[plan_bank];
  end
 end
end
endmodule
