// VIDEO-001: FAT16 root HXV byte stream, derived from project FAT16 BMP reader.
// sector_ready permits a whole 512-byte sector; it cannot stop an in-flight sector.
// File length bounds traversal; player validates HXAV header before any frame commit.
module fat16_movie_read # (parameter integer READ_TIMEOUT=200000000)(
 input audio_only,input sector_ready, output [31:0] stream_size,output [4:0] sd_read_count,
 input clk,rst,scan_start,scan_resume,load_start,load_abort,sd_init_done,
 input [31:0] scan_start_sector,scan_max_sector,load_sector,
 input [2:0] scan_target_count,
 input [15:0] bmp_width,bmp_height,
 output ready, output reg scan_done,scan_found_valid,
 output reg [31:0] scan_found_sector,output reg [2:0] scan_found_total,
 output reg [3:0] state_code,output reg write_req,input write_req_ack,
 output reg sd_sec_read,output reg [31:0] sd_sec_read_addr,
 input [7:0] sd_sec_read_data,input sd_sec_read_data_valid,sd_sec_read_end,
 output reg bmp_data_wr_en,output reg [23:0] bmp_data
);
localparam IDLE=0,START_READ=1,READ=2,BOOT_CHECK=3,LAYOUT=4,GEOMETRY=5,
 DIR_START=6,DIR_CHECK=7,HEADER_CHECK=8,WRITE_WAIT=9,DATA_NEXT=10,
 FAT_CHECK=11,FAIL=12,LAYOUT_ROOT=13,LAYOUT_DATA=14,COUNT_CLUSTERS=15,ADDR_SUB=16,ADDR_SHIFT=17,ADDR_ADD=18,CALC_LIMIT=19,GEOMETRY_PRECHECK=20,FAT_CACHE_WAIT=21,FAT_CACHE_USE=22,FAT_VALIDATE=23,DIR_PRECHECK=24,DATA_DECIDE=25;
localparam BOOT_SETTLE=26;
localparam K_BOOT=0,K_DIR=1,K_HEADER=2,K_DATA=3,K_FAT=4;
reg [4:0] state,after_read;
reg [15:0] address_cluster,address_minus;
reg [22:0] address_offset;
reg [16:0] cluster_limit;
reg geometry_ok,boot_fields_ok,header_ok,format_ok,length_ok,signature_ok,partition_ok;
reg fat_bad;
reg dir_exhausted,stream_empty,cluster_more;

reg [2:0] kind;
reg [9:0] byte_index;
reg [31:0] timeout_count;
reg mounted,partition_tried,loading;
reg sector_permit;
// A sector can only be launched from START_READ, after READ -> DATA_NEXT.
// No bytes arrive in that decision interval, so a registered permission cannot
// overrun the decoder. It removes ring-bank selection from the FAT state CE.
always @(posedge clk or posedge rst)if(rst)sector_permit<=0;else sector_permit<=sector_ready;
reg [15:0] bytes_per_sector,reserved_sectors,root_entries,total16,fat_sectors,signature;
reg [7:0] sectors_per_cluster,fats,partition_type;
reg [31:0] total32,partition_lba,volume_lba,volume_end,fat_lba,root_lba,data_lba;
reg [31:0] total_sectors,root_sectors,cluster_count,fat_region_sectors;
reg [3:0] cluster_shift;
reg [31:0] dir_lba,dir_end;
reg [4:0] dir_skip,candidate_next;
reg directory_end,candidate;
reg [7:0] entry_first,entry_attr,ext0,ext1,ext2;
reg [15:0] entry_cluster,entry_high,candidate_cluster;
reg [31:0] entry_size,candidate_size;
reg [15:0] current_cluster,first_cluster,fat_value;
reg [7:0] cluster_sector;
always @(posedge clk)fat_bad<=fat_value<2 || fat_value>=16'hfff0 || {1'b0,fat_value}>=cluster_limit || fat_value==current_cluster || fat_value==first_cluster;
// Never prefetch across a FAT cluster boundary or past the allocated volume.
wire [8:0] cluster_remaining={1'b0,sectors_per_cluster}-{1'b0,cluster_sector};
assign sd_read_count=kind==K_DATA ? (cluster_remaining>=16?5'd16:cluster_remaining[4:0]) : 5'd1;
reg [15:0] magic,planes,bits;
reg [31:0] file_length,pixel_offset,dib_size,width,height,compression;
reg [31:0] bytes_left;
reg [1:0] channel;
reg [31:0] saved_size;
reg [31:0] expected_size;
reg [31:0] pixel_end;
always @(posedge clk)begin
 if(rst)begin header_ok<=0;format_ok<=0;length_ok<=0;pixel_end<=0;boot_fields_ok<=0;signature_ok<=0;partition_ok<=0;end
 else begin
  pixel_end<=pixel_offset+32'd921600;
  format_ok<=magic==16'h4d42 && dib_size>=40 && planes==1 &&
   width=={16'd0,bmp_width} && height=={16'd0,bmp_height} && bits==24 && compression==0;
  length_ok<=pixel_offset>=54 && pixel_offset<=4096 && file_length>=pixel_end && file_length<=expected_size;
  header_ok<=format_ok && length_ok;
  boot_fields_ok<=bytes_per_sector==512 && reserved_sectors!=0 && root_entries!=0 &&
   fat_sectors!=0 && (fats==1 || fats==2) && log_cluster(sectors_per_cluster)!=15;
  signature_ok<=signature==16'haa55;
  partition_ok<=partition_lba!=0 && partition_lba<32'h04000000 &&
    (partition_type==4 || partition_type==6 || partition_type==14);
 end
end
// Byte decoding is a separate registered stage, reducing state fanout.
reg boot_write,entry_eligible;
reg [9:0] boot_index;
reg [7:0] boot_data;
always @(posedge clk or posedge rst)begin
 if(rst)begin
  boot_write<=0;boot_index<=0;boot_data<=0;entry_eligible<=0;
  bytes_per_sector<=0;reserved_sectors<=0;root_entries<=0;total16<=0;
  fat_sectors<=0;signature<=0;sectors_per_cluster<=0;fats<=0;partition_type<=0;
  total32<=0;partition_lba<=0;
 end else begin
  boot_write<=state==READ && sd_init_done && !load_abort && sd_sec_read_data_valid && kind==K_BOOT;
  boot_index<=byte_index;boot_data<=sd_sec_read_data;
  entry_eligible<=!directory_end && !candidate && {1'b0,byte_index[8:5]}>=dir_skip &&
           entry_first!=8'he5 && entry_first!=0 && (entry_attr & 8'h18)==0 &&
           (ext0=="H" || ext0=="h") && (ext1=="X" || ext1=="x") && (audio_only ? (ext2=="A" || ext2=="a") : (ext2=="V" || ext2=="v")) &&
           entry_high==0 && entry_cluster>=2 && {1'b0,entry_cluster}<cluster_limit;
  if(boot_write)begin
case(boot_index)
        11:bytes_per_sector[7:0]<=boot_data;12:bytes_per_sector[15:8]<=boot_data;
        13:sectors_per_cluster<=boot_data;
        14:reserved_sectors[7:0]<=boot_data;15:reserved_sectors[15:8]<=boot_data;
        16:fats<=boot_data;
        17:root_entries[7:0]<=boot_data;18:root_entries[15:8]<=boot_data;
        19:total16[7:0]<=boot_data;20:total16[15:8]<=boot_data;
        22:fat_sectors[7:0]<=boot_data;23:fat_sectors[15:8]<=boot_data;
        32:total32[7:0]<=boot_data;33:total32[15:8]<=boot_data;
        34:total32[23:16]<=boot_data;35:total32[31:24]<=boot_data;
        450:partition_type<=boot_data;
        454:partition_lba[7:0]<=boot_data;455:partition_lba[15:8]<=boot_data;
        456:partition_lba[23:16]<=boot_data;457:partition_lba[31:24]<=boot_data;
        510:signature[7:0]<=boot_data;511:signature[15:8]<=boot_data;
        default:;
       endcase

  end
 end
end
wire [8:0] fat_offset={current_cluster[7:0],1'b0};
assign ready=(state==IDLE || state==FAIL);
// Two FAT sectors fit one 9K RAM (512 x 16). Alternating fragmented clusters
// must not thrash a single FAT cache entry. Tags and replacement are local.
reg [15:0] fat_cache[0:511];reg [7:0] fat_low;reg [15:0] fat_cached_value;
reg [1:0] fat_cache_valid;reg [7:0] fat_cache_page0,fat_cache_page1;
reg [31:0] wanted_fat_lba;
reg fat_replace,fat_read_bank,fat_hit0,fat_hit1;
always @(posedge clk)begin
 wanted_fat_lba<=fat_lba+{24'd0,current_cluster[15:8]};
 // FAT16 has at most 256 sectors of 256 entries. The mounted FAT base is
 // invariant while tags are valid, so store its relative 8-bit page only.
 fat_hit0<=fat_cache_valid[0] && fat_cache_page0==current_cluster[15:8];
 fat_hit1<=fat_cache_valid[1] && fat_cache_page1==current_cluster[15:8];
 fat_cached_value<=fat_cache[{fat_read_bank,current_cluster[7:0]}];
 if(state==READ && kind==K_FAT && sd_sec_read_data_valid)begin
  if(!byte_index[0])fat_low<=sd_sec_read_data;
  else fat_cache[{fat_replace,byte_index[8:1]}]<={sd_sec_read_data,fat_low};
 end
end
reg fat_publish;
always @(posedge clk or posedge rst)begin
 if(rst)fat_publish<=0;
 else fat_publish<=state==READ && kind==K_FAT && sd_sec_read_end && byte_index==512 && sd_init_done && !load_abort && !scan_start;
end
always @(posedge clk or posedge rst)begin
 if(rst)begin fat_cache_page0<=0;fat_cache_page1<=0;end
 else if(fat_publish)begin
  if(fat_replace)fat_cache_page1<=current_cluster[15:8];else fat_cache_page0<=current_cluster[15:8];
 end
end
always @(posedge clk or posedge rst)begin
 if(rst)begin fat_cache_valid<=0;fat_replace<=0;end
 else if(!sd_init_done || load_abort || scan_start)begin fat_cache_valid<=0;fat_replace<=0;end
 else if(fat_publish)begin fat_cache_valid[fat_replace]<=1;fat_replace<=~fat_replace;end
end
assign stream_size=expected_size;
integer i;
function [3:0] log_cluster;
 input [7:0] n;
 begin case(n)
  1:log_cluster=0;2:log_cluster=1;4:log_cluster=2;8:log_cluster=3;
  16:log_cluster=4;32:log_cluster=5;64:log_cluster=6;128:log_cluster=7;
  default:log_cluster=15;
 endcase end
endfunction
always @(posedge clk or posedge rst) begin
 if(rst)begin
  state<=IDLE;after_read<=IDLE;fat_read_bank<=0;kind<=0;byte_index<=0;timeout_count<=0;
  address_cluster<=0;address_minus<=0;address_offset<=0;cluster_limit<=0;geometry_ok<=0;
  dir_exhausted<=0;stream_empty<=0;cluster_more<=0;
  mounted<=0;partition_tried<=0;loading<=0;volume_lba<=0;volume_end<=0;

  fat_lba<=0;root_lba<=0;data_lba<=0;
  fat_region_sectors<=0;total_sectors<=0;root_sectors<=0;cluster_count<=0;cluster_shift<=0;
  dir_lba<=0;dir_end<=0;dir_skip<=0;candidate_next<=0;
  directory_end<=0;candidate<=0;entry_first<=0;entry_attr<=0;
  ext0<=0;ext1<=0;ext2<=0;entry_cluster<=0;entry_high<=0;candidate_cluster<=0;
  entry_size<=0;candidate_size<=0;current_cluster<=0;first_cluster<=0;
  fat_value<=0;cluster_sector<=0;magic<=0;planes<=0;bits<=0;
  file_length<=0;pixel_offset<=0;dib_size<=0;width<=0;height<=0;compression<=0;
  bytes_left<=0;channel<=0;expected_size<=0;
  saved_size<=0;
  scan_done<=0;scan_found_valid<=0;scan_found_sector<=0;scan_found_total<=0;
  state_code<=0;write_req<=0;sd_sec_read<=0;sd_sec_read_addr<=0;
  bmp_data_wr_en<=0;bmp_data<=0;
 end else begin
  scan_found_valid<=0;bmp_data_wr_en<=0;
  if(!sd_init_done || load_abort)begin
   state<=IDLE;mounted<=0;sd_sec_read<=0;write_req<=0;state_code<=0;
   scan_done<=0;scan_found_total<=0;partition_tried<=0;
  end else begin
   case(state)
    IDLE:begin
     sd_sec_read<=0;write_req<=0;
     if(scan_start)begin
      mounted<=0;partition_tried<=0;volume_lba<=0;
      scan_done<=0;scan_found_total<=0;loading<=0;
      sd_sec_read_addr<=0;kind<=K_BOOT;after_read<=BOOT_SETTLE;state<=START_READ;
      state_code<=2;
     end else if(load_start && mounted)begin
      loading<=1;first_cluster<=load_sector[15:0];current_cluster<=load_sector[15:0];
      expected_size<=saved_size;
      address_cluster<=load_sector[15:0];kind<=K_HEADER;
      after_read<=HEADER_CHECK;state<=ADDR_SUB;
     end else if(scan_resume && mounted && !scan_done)state<=DIR_PRECHECK;
    end
    START_READ:if(kind!=K_DATA || sector_permit)begin
     byte_index<=0;timeout_count<=0;sd_sec_read<=1;state<=READ;
    end
    READ:begin
     if(timeout_count>=READ_TIMEOUT-1)begin
      state<=FAIL;state_code<=4'he;scan_done<=1;sd_sec_read<=0;write_req<=0;
     end else timeout_count<=timeout_count+1'b1;
     if(sd_sec_read_data_valid)begin
      byte_index<=byte_index+1'b1;
      case(kind)
       K_DIR:begin
        case(byte_index[4:0])
         0:begin entry_first<=sd_sec_read_data;if(sd_sec_read_data==0)directory_end<=1;end
         8:ext0<=sd_sec_read_data;9:ext1<=sd_sec_read_data;10:ext2<=sd_sec_read_data;
         11:entry_attr<=sd_sec_read_data;
         20:entry_high[7:0]<=sd_sec_read_data;21:entry_high[15:8]<=sd_sec_read_data;
         26:entry_cluster[7:0]<=sd_sec_read_data;27:entry_cluster[15:8]<=sd_sec_read_data;
         28:entry_size[7:0]<=sd_sec_read_data;29:entry_size[15:8]<=sd_sec_read_data;
         30:entry_size[23:16]<=sd_sec_read_data;
         31:begin
          if(entry_eligible && {sd_sec_read_data,entry_size[23:0]}>=512)begin
            candidate<=1;candidate_cluster<=entry_cluster;
            candidate_size<={sd_sec_read_data,entry_size[23:0]};
            candidate_next<={1'b0,byte_index[8:5]}+1'b1;
          end
         end
         default:;
        endcase
       end
       K_HEADER:case(byte_index)
        0:magic[7:0]<=sd_sec_read_data;1:magic[15:8]<=sd_sec_read_data;
        2:file_length[7:0]<=sd_sec_read_data;3:file_length[15:8]<=sd_sec_read_data;
        4:file_length[23:16]<=sd_sec_read_data;5:file_length[31:24]<=sd_sec_read_data;
        10:pixel_offset[7:0]<=sd_sec_read_data;11:pixel_offset[15:8]<=sd_sec_read_data;
        12:pixel_offset[23:16]<=sd_sec_read_data;13:pixel_offset[31:24]<=sd_sec_read_data;
        14:dib_size[7:0]<=sd_sec_read_data;15:dib_size[15:8]<=sd_sec_read_data;
        16:dib_size[23:16]<=sd_sec_read_data;17:dib_size[31:24]<=sd_sec_read_data;
        18:width[7:0]<=sd_sec_read_data;19:width[15:8]<=sd_sec_read_data;
        20:width[23:16]<=sd_sec_read_data;21:width[31:24]<=sd_sec_read_data;
        22:height[7:0]<=sd_sec_read_data;23:height[15:8]<=sd_sec_read_data;
        24:height[23:16]<=sd_sec_read_data;25:height[31:24]<=sd_sec_read_data;
        26:planes[7:0]<=sd_sec_read_data;27:planes[15:8]<=sd_sec_read_data;
        28:bits[7:0]<=sd_sec_read_data;29:bits[15:8]<=sd_sec_read_data;
        30:compression[7:0]<=sd_sec_read_data;31:compression[15:8]<=sd_sec_read_data;
        32:compression[23:16]<=sd_sec_read_data;33:compression[31:24]<=sd_sec_read_data;
        default:;
       endcase
       K_DATA:begin
        if(bytes_left!=0)begin bytes_left<=bytes_left-1'b1;bmp_data_wr_en<=1;bmp_data<={16'd0,sd_sec_read_data};end
       end
       K_FAT:begin
        if(byte_index=={1'b0,fat_offset})fat_value[7:0]<=sd_sec_read_data;
        if(byte_index=={1'b0,fat_offset}+10'd1)fat_value[15:8]<=sd_sec_read_data;
       end
       default:;
      endcase
     end
     if(sd_sec_read_end)begin
      sd_sec_read<=0;
      if(byte_index!=512)begin state<=FAIL;state_code<=4'he;scan_done<=1;end
      else state<=after_read;
     end
    end
    BOOT_SETTLE:state<=BOOT_CHECK;
    BOOT_CHECK:begin
     if(!signature_ok)begin state<=FAIL;state_code<=4'hb;scan_done<=1;end
     else if(boot_fields_ok)begin
       total_sectors<=total16!=0 ? {16'd0,total16} : total32;
       root_sectors<=({16'd0,root_entries}+15)>>4;
       cluster_shift<=log_cluster(sectors_per_cluster);state<=LAYOUT;
     end else if(!partition_tried && partition_ok)begin
      partition_tried<=1;volume_lba<=partition_lba;sd_sec_read_addr<=partition_lba;
      kind<=K_BOOT;after_read<=BOOT_SETTLE;state<=START_READ;
     end else begin state<=FAIL;state_code<=4'hb;scan_done<=1;end
    end
    LAYOUT:begin
     fat_lba<=volume_lba+{16'd0,reserved_sectors};
     fat_region_sectors<=({16'd0,fat_sectors}<<(fats==2));
     volume_end<=volume_lba+total_sectors;state<=LAYOUT_ROOT;
    end
    LAYOUT_ROOT:begin root_lba<=fat_lba+fat_region_sectors;state<=LAYOUT_DATA;end
    LAYOUT_DATA:begin data_lba<=root_lba+root_sectors;state<=COUNT_CLUSTERS;end
    COUNT_CLUSTERS:begin cluster_count<=(volume_end-data_lba)>>cluster_shift;state<=CALC_LIMIT;end
    CALC_LIMIT:begin cluster_limit<=cluster_count[16:0]+17'd2;state<=GEOMETRY_PRECHECK;end
    GEOMETRY_PRECHECK:begin
     geometry_ok<=total_sectors!=0 && total_sectors<=32'h04000000 && data_lba<volume_end &&
       cluster_count>=4085 && cluster_count<65525 && {15'd0,cluster_limit}<=({16'd0,fat_sectors}<<8);
     state<=GEOMETRY;
    end
    GEOMETRY:begin
     if(!geometry_ok)begin state<=FAIL;state_code<=4'hb;scan_done<=1;end
     else begin mounted<=1;dir_lba<=root_lba;dir_end<=data_lba;dir_skip<=0;state<=DIR_PRECHECK;end
    end
    ADDR_SUB:begin address_minus<=address_cluster-16'd2;state<=ADDR_SHIFT;end
    ADDR_SHIFT:begin address_offset<={7'd0,address_minus}<<cluster_shift;state<=ADDR_ADD;end
    ADDR_ADD:begin sd_sec_read_addr<=data_lba+{9'd0,address_offset};state<=START_READ;end
    // Compare before branching, including after a directory-sector advance.
    DIR_PRECHECK:begin dir_exhausted<=dir_lba>=dir_end;state<=DIR_START;end
    DIR_START:begin
     state_code<=2;loading<=0;
     if(dir_exhausted || scan_found_total>=scan_target_count || scan_found_total>=4)begin
      scan_done<=1;state<=IDLE;
     end else if(dir_skip==16)begin dir_lba<=dir_lba+1'b1;dir_skip<=0;state<=DIR_PRECHECK;end
     else begin
      candidate<=0;directory_end<=0;sd_sec_read_addr<=dir_lba;
      kind<=K_DIR;after_read<=DIR_CHECK;state<=START_READ;
     end
    end
    DIR_CHECK:begin
     if(candidate)begin
      dir_skip<=candidate_next;first_cluster<=candidate_cluster;
      expected_size<=candidate_size;address_cluster<=candidate_cluster;
      kind<=K_HEADER;after_read<=HEADER_CHECK;state<=ADDR_SUB;
     end else if(directory_end)begin scan_done<=1;state<=IDLE;end
     else begin dir_lba<=dir_lba+1'b1;dir_skip<=0;state<=IDLE;end
    end
    HEADER_CHECK:begin
     if(1'b1)begin
      if(loading)begin
       current_cluster<=first_cluster;cluster_sector<=0;bytes_left<=expected_size;channel<=0;
       write_req<=1;state<=WRITE_WAIT;state_code<=3;
      end else begin
       saved_size<=expected_size;
       scan_found_valid<=1;scan_found_sector<={16'd0,first_cluster};
       scan_found_total<=1;scan_done<=1;
       state<=IDLE;
      end
     end else begin state<=IDLE;state_code<=4'hc;end
    end
    WRITE_WAIT:if(write_req_ack)begin
     write_req<=0;address_cluster<=first_cluster;
     kind<=K_DATA;after_read<=DATA_NEXT;state<=ADDR_SUB;state_code<=4;
    end
    DATA_NEXT:begin
     // No data is accepted after sector completion until the next READ.
     stream_empty<=bytes_left==0;cluster_more<=cluster_sector+1'b1<sectors_per_cluster;
     state<=DATA_DECIDE;
    end
    DATA_DECIDE:begin
     if(stream_empty)begin state<=IDLE;state_code<=1;end
     else if(cluster_more)begin
      cluster_sector<=cluster_sector+1'b1;sd_sec_read_addr<=sd_sec_read_addr+1'b1;
      kind<=K_DATA;after_read<=DATA_NEXT;state<=START_READ;
     end else begin
      sd_sec_read_addr<=fat_lba+{24'd0,current_cluster[15:8]};
      kind<=K_FAT;after_read<=FAT_VALIDATE;
      fat_read_bank<=!fat_hit0;state<=(fat_hit0 || fat_hit1)?FAT_CACHE_WAIT:START_READ;
     end
    end
    FAT_CACHE_WAIT:state<=FAT_CACHE_USE;
    FAT_CACHE_USE:begin fat_value<=fat_cached_value;state<=FAT_VALIDATE;end
    FAT_VALIDATE:state<=FAT_CHECK;
    FAT_CHECK:begin
     if(fat_bad)begin
      state<=IDLE;state_code<=4'hd;
     end else begin
      current_cluster<=fat_value;cluster_sector<=0;address_cluster<=fat_value;
      kind<=K_DATA;after_read<=DATA_NEXT;state<=ADDR_SUB;
     end
    end
    FAIL:begin sd_sec_read<=0;write_req<=0;end
    default:begin state<=FAIL;state_code<=4'he;scan_done<=1;end
   endcase
  end
 end
end
endmodule
