// BASE-FILE: read-only FAT16, 512-byte sectors, root-directory 8.3 BMPs.
// Supports superfloppy or first MBR partition (04/06/0E), fragmented chains.
// scan_found_sector/load_sector carry FIRST CLUSTER IDs, not physical LBAs.
// BMP: DIB>=40, 1..1280 x 1..1024 bottom-up BGR24 -> FPGA 640x480; padded rows.
// One streamed sector at a time. No full-sector register array or division.
module fat16_bmp_read # (parameter integer READ_TIMEOUT=200000000, PARALLEL_META=1, LOAD_BY_INDEX=0, CATALOG=4, INDEX_BITS=$clog2(CATALOG), COUNT_BITS=$clog2(CATALOG+1))(
 input clk,rst,scan_start,scan_resume,load_start,load_abort,sd_init_done,
 input [31:0] scan_start_sector,scan_max_sector,load_sector,
 input [COUNT_BITS-1:0] scan_target_count,
 input [15:0] bmp_width,bmp_height,
 output ready, output reg scan_done,scan_found_valid,
 output reg [31:0] scan_found_sector,output reg [COUNT_BITS-1:0] scan_found_total,
 output reg [3:0] state_code,output reg write_req,input write_req_ack,
 output reg sd_sec_read,output reg [31:0] sd_sec_read_addr,output [5:0] sd_read_count,
 input [7:0] sd_sec_read_data,input sd_sec_read_data_valid,sd_sec_read_end,
 input output_ready,output bmp_data_wr_en,output [23:0] bmp_data,
 output reg [CATALOG*11-1:0] native_widths,native_heights,
 input [INDEX_BITS-1:0] query_index,input query_height,output [15:0] query_data,output query_ready,
 output [10:0] loaded_width,loaded_height
);
localparam IDLE=0,START_READ=1,READ=2,BOOT_CHECK=3,LAYOUT=4,GEOMETRY=5,
 DIR_START=6,DIR_CHECK=7,HEADER_CHECK=8,WRITE_WAIT=9,DATA_NEXT=10,
 FAT_CHECK=11,FAIL=12,LAYOUT_ROOT=13,LAYOUT_DATA=14,COUNT_CLUSTERS=15,ADDR_SUB=16,ADDR_SHIFT=17,ADDR_ADD=18,CALC_LIMIT=19,GEOMETRY_PRECHECK=20,SIZE_SELECT=21,DATA_DRAIN=22,CATALOG_STORE=23,DIR_PRECHECK=24,SIZE_WAIT=25,SIZE_USE=26,SIZE_MATCH=27,CATALOG_HIGH=28,SIZE_HIGH_WAIT=29,SIZE_HIGH_USE=30,LOOK_START=31,LOOK_WAIT=32,LOOK_USE=33,CATALOG_SIZE_HI=34,CATALOG_WIDTH=35,CATALOG_HEIGHT=36,INDEX_WAIT=37,INDEX_USE=38,LOOK_DELAY=39,INDEX_DELAY=40,SIZE_DELAY=41,HIGH_DELAY=42;
localparam BOOT_SETTLE=43;
localparam K_BOOT=0,K_DIR=1,K_HEADER=2,K_DATA=3,K_FAT=4;
(* fsm_encoding="sequential" *) reg [5:0] state;
reg [5:0] after_read;
reg [INDEX_BITS-1:0] lookup_index;
reg [15:0] address_cluster,address_minus;
reg [22:0] address_offset;
reg [16:0] cluster_limit;
reg geometry_ok,boot_fields_ok,header_ok,format_ok,length_ok,partition_ok,signature_ok;
reg [2:0] kind;
reg [9:0] byte_index;
reg [31:0] timeout_count;
reg mounted,partition_tried,loading;
reg [1:0] sector_bytes_ok,signature_bytes_ok;
reg [15:0] reserved_sectors,root_entries,total16,fat_sectors;
reg [7:0] sectors_per_cluster,fats,partition_type;
reg [31:0] total32,partition_lba,volume_lba,volume_end,fat_lba,root_lba,data_lba;
reg [31:0] total_sectors,root_sectors,cluster_count,fat_region_sectors;
reg [3:0] cluster_shift;
// Mount-only division by the power-of-two cluster size. One bit per cycle
// avoids a wide barrel shifter after the 32-bit volume subtraction. No sector
// is launched until GEOMETRY has validated the complete result.
localparam GEOMETRY_SHIFT=44;
reg [3:0] geometry_shift_left;
reg [31:0] dir_lba,dir_end;
reg [4:0] dir_skip,candidate_next;
reg directory_end,candidate;
reg [7:0] entry_first,entry_attr,ext0,ext1,ext2;
reg [15:0] entry_cluster,entry_high,candidate_cluster;
reg [31:0] entry_size,candidate_size;
reg [15:0] current_cluster,first_cluster,fat_value;
reg [7:0] cluster_sector;
// Store equality/range evidence per incoming byte, not discarded upper bits.
// Each byte independently overwrites its predicate, including a later good file
// after a bad one. All header bytes are still read and validated.
reg [1:0] magic_ok,planes_ok,bits_ok;
reg [3:0] compression_nonzero;
reg [2:0] width_high,height_high,dib_high;
reg [10:0] width,height;
reg [7:0] dib_low;
reg [31:0] file_length,pixel_offset;
reg [31:0] file_position;
reg [1:0] channel;
// Five 16-bit words per entry, padded to eight: cluster, length low/high,
// native width/height. One spare 32K block replaces all catalog
// comparators and resettable metadata. Count is the validity boundary.
reg [31:0] expected_size;
reg [INDEX_BITS+2:0] size_address;
wire [15:0] raw_size_q;reg [15:0] size_q,size_low;
always @(posedge clk)size_q<=raw_size_q;
wire catalog_store=(state==CATALOG_STORE) || (state==CATALOG_HIGH) || (state==CATALOG_SIZE_HI) || (state==CATALOG_WIDTH) || (state==CATALOG_HEIGHT);
wire [2:0] store_field=(state==CATALOG_STORE)?3'd0:(state==CATALOG_HIGH)?3'd1:(state==CATALOG_SIZE_HI)?3'd2:(state==CATALOG_WIDTH)?3'd3:3'd4;
wire lookup_busy=(state==LOOK_START) || (state==LOOK_WAIT) || (state==LOOK_USE) || (state==SIZE_WAIT) || (state==SIZE_USE) || (state==SIZE_HIGH_WAIT) || (state==SIZE_HIGH_USE) || (state==INDEX_WAIT) || (state==INDEX_USE) || (state==LOOK_DELAY) || (state==INDEX_DELAY) || (state==SIZE_DELAY) || (state==HIGH_DELAY);
reg catalog_we;reg [INDEX_BITS+2:0] catalog_wa;reg [15:0] catalog_wd;
wire query_free=!catalog_store && !catalog_we && !lookup_busy;
reg [1:0] query_free_d;
wire [INDEX_BITS+2:0] ram_address=catalog_we?catalog_wa:lookup_busy?size_address:{query_index,query_height?3'd4:3'd3};
wire [15:0] ram_data=(state==CATALOG_STORE)?first_cluster:(state==CATALOG_HIGH)?expected_size[15:0]:(state==CATALOG_SIZE_HI)?expected_size[31:16]:(state==CATALOG_WIDTH)?{5'd0,width[10:0]}:{5'd0,height[10:0]};
// EG4 vendor primitive template: DP16K, 16-bit data, synchronous NOREG
// output. Written entries only; there is no memory-reset or initial-data need.
// UI_FONT_SIM is the existing portable-simulation switch for vendor models.
`ifdef UI_FONT_SIM
reg [15:0] catalog[0:CATALOG*8-1];reg [15:0] sim_q;
always @(posedge clk)begin
 if(catalog_we)catalog[ram_address]<=catalog_wd;
 sim_q<=catalog[ram_address];
end
assign raw_size_q=sim_q;
`else
EG_PHY_BRAM32K #(.MODE("DP16K"),.DATA_WIDTH_A("16"),.DATA_WIDTH_B("16"),
 .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL")) catalog_memory(
 .doa(raw_size_q),.dob(),.dia(catalog_wd),.dib(16'd0),.addra({{(8-INDEX_BITS){1'b0}},ram_address}),.addrb(11'd0),
 .bytea(1'b0),.bytewea(1'b0),.byteb(1'b0),.byteweb(1'b0),.csa(1'b1),.wea(catalog_we),.csb(1'b1),.web(1'b1),
 .clka(clk),.clkb(1'b0),.rsta(1'b0),.rstb(1'b0),.ocea(1'b1),.oceb(1'b0));
`endif
always @(posedge clk)begin
 catalog_we<=catalog_store && !rst;
 catalog_wa<={scan_found_total[INDEX_BITS-1:0],store_field};catalog_wd<=ram_data;
 query_free_d<={query_free_d[0],query_free};
end
assign query_data=size_q;
assign query_ready=query_free && (&query_free_d);
assign loaded_width=width[10:0];assign loaded_height=height[10:0];
reg [31:0] pixel_end;
reg [12:0] row_stride;
reg [31:0] pixel_bytes;
wire scale_sector_done;
// Writer ACK precedes the first K_DATA request by at least four state steps.
// Isolate FAT state decode from scaler position-counter reset selection.
reg scaler_start;
always @(posedge clk or posedge rst)begin
 if(rst)scaler_start<=1'b0;
 else scaler_start<=(state==WRITE_WAIT) && write_req_ack && sd_init_done && !load_abort;
end
bmp_scale_stream scaler(.clk(clk),.rst(rst || load_abort || !sd_init_done),
 .start(scaler_start),.width(width[10:0]),.height(height[10:0]),
 .pixel_offset(pixel_offset),.pixel_end(pixel_end),.row_stride(row_stride),
 .byte_valid((state==READ) && kind==K_DATA && sd_sec_read_data_valid),.byte_data(sd_sec_read_data),
 .sector_end((state==READ) && kind==K_DATA && sd_sec_read_end),.sector_done(scale_sector_done),
 .output_ready(output_ready),.pixel_valid(bmp_data_wr_en),.pixel(bmp_data));
always @(posedge clk)begin
 if(rst)begin header_ok<=0;format_ok<=0;length_ok<=0;pixel_end<=0;row_stride<=0;pixel_bytes<=0;boot_fields_ok<=0;partition_ok<=0;signature_ok<=0;end
 else begin
  row_stride<=((width[10:0]*13'd3)+13'd3)&13'h1ffc;
  pixel_bytes<=row_stride*height[10:0];
  pixel_end<=pixel_offset+pixel_bytes;
  format_ok<=(&magic_ok) && ((|dib_high) || dib_low>=8'd40) && (&planes_ok) &&
   width_high==0 && width>=1 && width<=1280 && height_high==0 && height>=1 && height<=1024 && (&bits_ok) && compression_nonzero==0;
  length_ok<=pixel_offset>=54 && pixel_offset<=4096 && file_length>=pixel_end && file_length<=expected_size;
  header_ok<=format_ok && length_ok;
  boot_fields_ok<=(&sector_bytes_ok) && reserved_sectors!=0 && root_entries!=0 &&
   fat_sectors!=0 && (fats==1 || fats==2) && log_cluster(sectors_per_cluster)!=15;
  partition_ok<=partition_lba!=0 && partition_lba<32'h04000000 &&
    (partition_type==4 || partition_type==6 || partition_type==14);
  signature_ok<=(&signature_bytes_ok);
 end
end
reg dir_limit,entry_eligible,pixels_finished,fat_bad;
always @(posedge clk)begin
 if(rst)begin dir_limit<=0;entry_eligible<=0;pixels_finished<=0;fat_bad<=1;end
 else begin
  dir_limit<=dir_lba>=dir_end || scan_found_total>=scan_target_count || scan_found_total>=CATALOG;
  entry_eligible<=entry_first!=8'he5 && entry_first!=0 && (entry_attr & 8'h18)==0 &&
    (ext0=="B" || ext0=="b") && (ext1=="M" || ext1=="m") && (ext2=="P" || ext2=="p") &&
    entry_high==0 && entry_cluster>=2 && {1'b0,entry_cluster}<cluster_limit;
  pixels_finished<=file_position>=pixel_end;
  fat_bad<=fat_value<2 || fat_value>=16'hfff0 || {1'b0,fat_value}>=cluster_limit ||
        fat_value==current_cluster || fat_value==first_cluster;
 end
end
// Compatibility port for small legacy readers; the production library uses
// the query port and the loaded header, so this register bank is eliminated.
generate if(PARALLEL_META)begin: legacy_metadata
 always @(posedge clk or posedge rst)begin
  if(rst)begin native_widths<={CATALOG{11'd640}};native_heights<={CATALOG{11'd480}};end
  else if((state==CATALOG_HEIGHT))begin
   native_widths[scan_found_total[INDEX_BITS-1:0]*11+:11]<=width[10:0];
   native_heights[scan_found_total[INDEX_BITS-1:0]*11+:11]<=height[10:0];
  end
 end
end else begin
 always @*begin native_widths=0;native_heights=0;end
end endgenerate
wire [8:0] remaining_cluster={1'b0,sectors_per_cluster}-{1'b0,cluster_sector};
assign sd_read_count=kind==K_DATA ? (remaining_cluster>=8 ? 6'd8:remaining_cluster[5:0]):6'd1;
wire [8:0] fat_offset={current_cluster[7:0],1'b0};
assign ready=((state==IDLE) || (state==FAIL));
integer i;
function [3:0] log_cluster;
 input [7:0] n;
 begin case(n)
  1:log_cluster=0;2:log_cluster=1;4:log_cluster=2;8:log_cluster=3;
  16:log_cluster=4;32:log_cluster=5;64:log_cluster=6;128:log_cluster=7;
  default:log_cluster=15;
 endcase end
endfunction
// Decode and capture the incoming metadata byte once. The next clock writes
// its destination directly, without SD initialization/abort priority passing
// through each byte register's CE. Sector end follows the final valid byte.
reg meta_boot,meta_header;reg [9:0] meta_index;reg [7:0] meta_data;
always @(posedge clk or posedge rst)begin
 if(rst)begin meta_boot<=0;meta_header<=0;meta_index<=0;meta_data<=0;end
 else begin
  meta_boot<=(state==READ) && kind==K_BOOT && sd_sec_read_data_valid && sd_init_done && !load_abort;
  meta_header<=(state==READ) && kind==K_HEADER && sd_sec_read_data_valid && sd_init_done && !load_abort;
  meta_index<=byte_index;meta_data<=sd_sec_read_data;
 end
end
always @(posedge clk or posedge rst)begin
 if(rst)begin sector_bytes_ok<=2'b01;reserved_sectors<=0;root_entries<=0;total16<=0;fat_sectors<=0;signature_bytes_ok<=0;sectors_per_cluster<=0;fats<=0;partition_type<=0;total32<=0;partition_lba<=0;magic_ok<=0;planes_ok<=2'b10;bits_ok<=2'b10;file_length<=0;pixel_offset<=0;dib_low<=0;dib_high<=0;width<=0;width_high<=0;height<=0;height_high<=0;compression_nonzero<=0;end
 else begin
       if(meta_boot)case(meta_index)
        11:sector_bytes_ok[0]<=meta_data==8'h00;12:sector_bytes_ok[1]<=meta_data==8'h02;
        13:sectors_per_cluster<=meta_data;
        14:reserved_sectors[7:0]<=meta_data;15:reserved_sectors[15:8]<=meta_data;
        16:fats<=meta_data;
        17:root_entries[7:0]<=meta_data;18:root_entries[15:8]<=meta_data;
        19:total16[7:0]<=meta_data;20:total16[15:8]<=meta_data;
        22:fat_sectors[7:0]<=meta_data;23:fat_sectors[15:8]<=meta_data;
        32:total32[7:0]<=meta_data;33:total32[15:8]<=meta_data;
        34:total32[23:16]<=meta_data;35:total32[31:24]<=meta_data;
        450:partition_type<=meta_data;
        454:partition_lba[7:0]<=meta_data;455:partition_lba[15:8]<=meta_data;
        456:partition_lba[23:16]<=meta_data;457:partition_lba[31:24]<=meta_data;
        510:signature_bytes_ok[0]<=meta_data==8'h55;511:signature_bytes_ok[1]<=meta_data==8'haa;
        default:;
       endcase
       if(meta_header)case(meta_index)
        0:magic_ok[0]<=meta_data==8'd66;1:magic_ok[1]<=meta_data==8'd77;
        2:file_length[7:0]<=meta_data;3:file_length[15:8]<=meta_data;
        4:file_length[23:16]<=meta_data;5:file_length[31:24]<=meta_data;
        10:pixel_offset[7:0]<=meta_data;11:pixel_offset[15:8]<=meta_data;
        12:pixel_offset[23:16]<=meta_data;13:pixel_offset[31:24]<=meta_data;
        14:dib_low<=meta_data;15:dib_high[0]<=|meta_data;
        16:dib_high[1]<=|meta_data;17:dib_high[2]<=|meta_data;
        18:width[7:0]<=meta_data;19:begin width[10:8]<=meta_data[2:0];width_high[0]<=|meta_data[7:3];end
        20:width_high[1]<=|meta_data;21:width_high[2]<=|meta_data;
        22:height[7:0]<=meta_data;23:begin height[10:8]<=meta_data[2:0];height_high[0]<=|meta_data[7:3];end
        24:height_high[1]<=|meta_data;25:height_high[2]<=|meta_data;
        26:planes_ok[0]<=meta_data==8'd1;27:planes_ok[1]<=meta_data==8'd0;
        28:bits_ok[0]<=meta_data==8'd24;29:bits_ok[1]<=meta_data==8'd0;
        30:compression_nonzero[0]<=|meta_data;31:compression_nonzero[1]<=|meta_data;
        32:compression_nonzero[2]<=|meta_data;33:compression_nonzero[3]<=|meta_data;
        default:;
       endcase
 end
end
always @(posedge clk or posedge rst) begin
 if(rst)begin
  state<=IDLE;after_read<=IDLE;kind<=0;lookup_index<=0;size_address<=0;size_low<=0;byte_index<=0;timeout_count<=0;
  address_cluster<=0;address_minus<=0;address_offset<=0;cluster_limit<=0;geometry_ok<=0;
  mounted<=0;partition_tried<=0;loading<=0;volume_lba<=0;volume_end<=0;
  
  
  fat_lba<=0;root_lba<=0;data_lba<=0;
  fat_region_sectors<=0;total_sectors<=0;root_sectors<=0;cluster_count<=0;cluster_shift<=0;geometry_shift_left<=0;
  dir_lba<=0;dir_end<=0;dir_skip<=0;candidate_next<=0;
  directory_end<=0;candidate<=0;entry_first<=0;entry_attr<=0;
  ext0<=0;ext1<=0;ext2<=0;entry_cluster<=0;entry_high<=0;candidate_cluster<=0;
  entry_size<=0;candidate_size<=0;current_cluster<=0;first_cluster<=0;
  fat_value<=0;cluster_sector<=0;
  
  file_position<=0;channel<=0;expected_size<=0;
  scan_done<=0;scan_found_valid<=0;scan_found_sector<=0;scan_found_total<=0;
  state_code<=0;write_req<=0;sd_sec_read<=0;sd_sec_read_addr<=0;
  
 end else begin
  scan_found_valid<=0;
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
      address_cluster<=load_sector[15:0];kind<=K_HEADER;
      after_read<=HEADER_CHECK;state<=LOAD_BY_INDEX?INDEX_WAIT:SIZE_MATCH;
      if(LOAD_BY_INDEX)size_address<={load_sector[INDEX_BITS-1:0],3'd0};
     end else if(scan_resume && mounted && !scan_done)state<=DIR_PRECHECK;
    end
    SIZE_MATCH:state<=LOOK_START;
    INDEX_WAIT:state<=INDEX_DELAY;
    INDEX_DELAY:state<=INDEX_USE;
    INDEX_USE:begin
     first_cluster<=size_q;current_cluster<=size_q;address_cluster<=size_q;
     size_address<=size_address+1'b1;state<=SIZE_WAIT;
    end
    LOOK_START:begin
     lookup_index<=0;size_address<=0;
     if(scan_found_total==0)begin
      if(loading)begin expected_size<=0;state<=ADDR_SUB;end else state<=CATALOG_STORE;
     end else state<=LOOK_WAIT;
    end
    LOOK_WAIT:state<=LOOK_DELAY;
    LOOK_DELAY:state<=LOOK_USE;
    LOOK_USE:begin
     if(size_q==first_cluster)begin
      if(loading)begin size_address<={lookup_index,3'd1};state<=SIZE_WAIT;end
      else state<=IDLE; // Duplicate first cluster: do not publish another ID.
     end else if({1'b0,lookup_index}+1'b1>=scan_found_total)begin
      if(loading)begin expected_size<=0;state<=ADDR_SUB;end else state<=CATALOG_STORE;
     end else begin lookup_index<=lookup_index+1'b1;size_address<=size_address+8;state<=LOOK_WAIT;end
    end
    SIZE_WAIT:state<=SIZE_DELAY;
    SIZE_DELAY:state<=SIZE_USE;
    SIZE_USE:begin size_low<=size_q;size_address<=size_address+1'b1;state<=SIZE_HIGH_WAIT;end
    SIZE_HIGH_WAIT:state<=HIGH_DELAY;
    HIGH_DELAY:state<=SIZE_HIGH_USE;
    SIZE_HIGH_USE:begin expected_size<={size_q,size_low};state<=ADDR_SUB;end
    START_READ:begin
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
          if(!directory_end && !candidate && {1'b0,byte_index[8:5]}>=dir_skip &&
           entry_eligible &&
           {sd_sec_read_data,entry_size[23:0]}>=58)begin
            candidate<=1;
            candidate_cluster<=entry_cluster;
            candidate_size<={sd_sec_read_data,entry_size[23:0]};
            candidate_next<={1'b0,byte_index[8:5]}+1'b1;
          end
         end
         default:;
        endcase
       end
       K_DATA:begin file_position<=file_position+1'b1;end
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
      else state<=kind==K_DATA?DATA_DRAIN:after_read;
     end
    end
    // Signature occupies the final sector bytes; allow its registered decode
    // to settle after the metadata byte stage before making a boot decision.
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
    COUNT_CLUSTERS:begin
     cluster_count<=volume_end-data_lba;geometry_shift_left<=cluster_shift;state<=GEOMETRY_SHIFT;
    end
    GEOMETRY_SHIFT:begin
     if(geometry_shift_left==0)state<=CALC_LIMIT;
     else begin cluster_count<=cluster_count>>1;geometry_shift_left<=geometry_shift_left-1'b1;end
    end
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
    DIR_PRECHECK:state<=DIR_START;
    DIR_START:begin
     state_code<=2;loading<=0;
     if(dir_limit)begin
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
     if(header_ok)begin
      if(loading)begin
       current_cluster<=first_cluster;cluster_sector<=0;file_position<=0;channel<=0;
       write_req<=1;state<=WRITE_WAIT;state_code<=3;
      end else begin
       state<=LOOK_START;
      end
     end else begin state<=IDLE;state_code<=4'hc;end
    end
    CATALOG_STORE:state<=CATALOG_HIGH;
    CATALOG_HIGH:state<=CATALOG_SIZE_HI;
    CATALOG_SIZE_HI:state<=CATALOG_WIDTH;
    CATALOG_WIDTH:state<=CATALOG_HEIGHT;
    CATALOG_HEIGHT:begin
     scan_found_valid<=1;scan_found_sector<={16'd0,first_cluster};
     scan_found_total<=scan_found_total+1'b1;
     if(scan_found_total+1'b1>=scan_target_count || scan_found_total==CATALOG-1)scan_done<=1;
     state<=IDLE;
    end
    WRITE_WAIT:if(write_req_ack)begin
     write_req<=0;address_cluster<=first_cluster;
     kind<=K_DATA;after_read<=DATA_NEXT;state<=ADDR_SUB;state_code<=4;
    end
    DATA_DRAIN:if(scale_sector_done)state<=DATA_NEXT;
    DATA_NEXT:begin
     if(pixels_finished)begin state<=IDLE;state_code<=1;end
     else if(cluster_sector+1'b1<sectors_per_cluster)begin
      cluster_sector<=cluster_sector+1'b1;sd_sec_read_addr<=sd_sec_read_addr+1'b1;
      kind<=K_DATA;after_read<=DATA_NEXT;state<=START_READ;
     end else begin
      sd_sec_read_addr<=fat_lba+{24'd0,current_cluster[15:8]};
      kind<=K_FAT;after_read<=FAT_CHECK;state<=START_READ;
     end
    end
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
