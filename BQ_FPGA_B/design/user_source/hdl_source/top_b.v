// BQ_FPGA_B controller, map, garden pages and runtime itinerary/QR.
// A supplies actual media snapshots; no pre-rendered page/effect is consumed.
module top(
 input clk,rst_n,key1,key_period,key2,input [3:0] switches,
 output [5:0] seg_sel,output [7:0] seg_data,
 output HDMI_CLK_P,HDMI_D2_P,HDMI_D1_P,HDMI_D0_P,HDMI_DDC_SCL,inout HDMI_DDC_SDA,
 inout sd_ncs,sd_mosi,output sd_dclk,input sd_miso,sd_dat1,sd_dat2,
 input hmi_rx,output hmi_tx,
 input phy_rxc,input [3:0] phy_rxd,input phy_rxctl,
 output phy_txc,output [3:0] phy_txd,output phy_txctl,output phy_mdc,inout phy_mdio
);
wire sd_card_clk,ext_mem_clk,ext_mem_clk_sft,video_clk,hdmi_5x_clk,sys_pll_lock,video_pll_lock;
wire rst_sd,rst_mem,rst_video,rst_net;reg [19:0] power_count=0;
always @(posedge clk)if(!rst_n || !sys_pll_lock || !video_pll_lock)power_count<=0;else if(power_count<1000000)power_count<=power_count+1'b1;
wire arst=!rst_n || !sys_pll_lock || !video_pll_lock || power_count<1000000;
sys_pll sys_pll_m0(.refclk(clk),.reset(1'b0),.extlock(sys_pll_lock),.clk0_out(sd_card_clk),.clk1_out(ext_mem_clk),.clk2_out(ext_mem_clk_sft));
video_pll video_pll_m0(.refclk(clk),.reset(1'b0),.extlock(video_pll_lock),.clk0_out(video_clk),.clk1_out(hdmi_5x_clk));
reset_release rs(.clk(sd_card_clk),.arst(arst),.rst(rst_sd));
reset_release rm(.clk(ext_mem_clk),.arst(arst),.rst(rst_mem));
reset_release rv(.clk(video_clk),.arst(arst),.rst(rst_video));
reset_release rn(.clk(clk),.arst(arst),.rst(rst_net));
// _NETWORK_BINDING: B receives desired state and reports actual frame commits.
wire [127:0] remote_state,applied_state,controller_request;
wire controller_commit;
wire remote_update,remote_stale,applied_update;
wire rx_delay_enabled;wire [15:0] network_bad,network_overflow;wire [31:0] network_reject;
wire network_link,network_peer,network_found,network_mdio_fault;
wire [4:0] network_phy_addr;
wire [31:0] network_phy_id,network_tx_count,network_rx_count,network_errors,network_retries;
// SW4 is an explicit active-high hardware arm. Leave OFF until the PHY/BANK
// voltage and RGMII delay straps have been checked on the physical board.
(* ASYNC_REG="TRUE" *) reg [1:0] network_arm;
always @(posedge clk or posedge rst_net)
 if(rst_net)network_arm<=0;else network_arm<={network_arm[0],switches[3]};
bq_network_link #(.BOARD_ID(2)) u_network(.clk(clk),.rst(rst_net),.io_enable(network_arm[1]),
 .local_state(controller_request),.local_state_commit(controller_commit),.remote_state(remote_state),.remote_update(remote_update),
 .link_up(network_link),.peer_online(network_peer),.stale(remote_stale),.phy_found(network_found),
 .phy_addr(network_phy_addr),.phy_id(network_phy_id),.tx_count(network_tx_count),.rx_count(network_rx_count),
 .error_count(network_errors),.retry_count(network_retries),.mdio_fault(network_mdio_fault),.rx_delay_enabled(rx_delay_enabled),.bad_frame_count(network_bad),.overflow_count(network_overflow),.rejected_count(network_reject),
 .phy_rxc(phy_rxc),.phy_rxd(phy_rxd),.phy_rxctl(phy_rxctl),.phy_txc(phy_txc),.phy_txd(phy_txd),
 .phy_txctl(phy_txctl),.phy_mdc(phy_mdc),.phy_mdio(phy_mdio));
wire [127:0] scene;wire [31:0] animation_ms;wire [10:0] photo_width,photo_height,video_photo_width,video_photo_height;
wire map_valid,photo_valid,video_map_valid,video_photo_valid,display_ack;
wire [1:0] photo_bank,video_photo_bank,protected_bank,write_bank;wire [3:0] photo_asset,desired_asset;
wire [3:0] pinned_valid,loading_asset;wire asset_complete;
(* ASYNC_REG="TRUE" *) reg [3:0] pinned_meta,pinned_video;
always @(posedge video_clk or posedge rst_video)if(rst_video)begin pinned_meta<=0;pinned_video<=0;end else begin pinned_meta<=pinned_valid;pinned_video<=pinned_meta;end
wire [3:0] loader_error,cache_valid;wire [15:0] cache_tags;
wire write_req,write_ack,write_ready,pixel_valid;wire [23:0] pixel;
wire [4:0] native_count;
wire native_init,native_valid,native_end,native_req,native_reset;wire [7:0] native_data;wire [31:0] native_addr;wire [3:0] native_error;wire [15:0] native_retries;
wire image_req,image_reset,image_valid,image_end,image_initialized;wire [31:0] image_lba;wire [4:0] image_count;wire [7:0] image_data;
wire font_request,font_sector_done,font_sector_busy;wire [31:0] font_lba;wire [3:0] font_sector_error;
wire [8:0] font_byte_address;wire [7:0] font_byte_data;
bq_font_sector_mux font_card(.sd_clk(sd_card_clk),.sd_rst(rst_sd),
 .image_request(image_req),.image_lba(image_lba),.image_count(image_count),.image_reset(image_reset),
 .image_valid(image_valid),.image_end(image_end),.image_data(image_data),.image_initialized(image_initialized),
 .native_initialized(native_init),.native_valid(native_valid),.native_end(native_end),.native_data(native_data),.native_error(native_error),
 .native_request(native_req),.native_lba(native_addr),.native_count(native_count),.native_reset(native_reset),
 .font_clk(clk),.font_rst(rst_net),.font_request(font_request),.font_lba(font_lba),.font_busy(font_sector_busy),
 .font_done(font_sector_done),.font_error(font_sector_error),.font_byte_address(font_byte_address),.font_byte_data(font_byte_data));
assign sd_ncs=1'bz;
sd_native_read #(.MAX_BURST(8)) native_sd(.clk(sd_card_clk),.rst(rst_sd || native_reset),.sd_clk(sd_dclk),.sd_cmd(sd_mosi),.sd_dat({sd_ncs,sd_dat2,sd_dat1,sd_miso}),
 .initialized(native_init),.read_req(native_req),.read_addr(native_addr),.read_count(native_count),.read_data(native_data),.read_valid(native_valid),.read_end(native_end),.error_code(native_error),.retries(native_retries));
wire init_done,refresh,mem_busy,reader_busy,writer_busy,mem_read,mem_read_valid,mem_write,frame_write_finish;
wire [20:0] read_addr,write_addr;wire [31:0] read_data,write_data;wire [3:0] write_mask;
reg write_toggle;
always @(posedge ext_mem_clk or posedge rst_mem)if(rst_mem)write_toggle<=0;else if(frame_write_finish)write_toggle<=~write_toggle;
b_asset_loader asset_library(.clk(sd_card_clk),.rst(rst_sd),.desired_asset(desired_asset),.pinned_valid(pinned_valid),.loading_asset(loading_asset),.asset_complete(asset_complete),.display_ack(display_ack),.displayed_bank(protected_bank),
 .write_finish_toggle(write_toggle),.map_valid(map_valid),.photo_valid(photo_valid),.photo_bank(photo_bank),.photo_asset(photo_asset),.photo_width(photo_width),.photo_height(photo_height),.error(loader_error),
 .cache_valid_out(cache_valid),.cache_tags(cache_tags),.write_bank(write_bank),.write_req(write_req),.write_req_ack(write_ack),.write_ready(write_ready),
 .write_en(pixel_valid),.pixel(pixel),.ext_init(image_initialized),.ext_valid(image_valid),.ext_end(image_end),.ext_data(image_data),.ext_req(image_req),.ext_addr(image_lba),.ext_count(image_count),.ext_reset(image_reset));
wire hs0,vs0,de0,frame_request;
video_timing_data timing(.video_clk(video_clk),.rst(rst_video),.read_req(frame_request),.read_req_ack(frame_request),.hs(hs0),.vs(vs0),.de(de0));
// B owns UART/session handling. Device queries stay usable when A is offline.
wire touch_valid,touch_done;wire [47:0] touch_command;wire [39:0] touch_response;
wire [15:0] touch_crc,touch_framing,touch_busy,touch_session;
wire [5:0] caption_text_address;wire [7:0] caption_text_data;
hmi_link #(.ALLOW_TEXT(1)) touch_link(.clk(clk),.rst(rst_net),.rx(hmi_rx),.tx(hmi_tx),
 .command_valid(touch_valid),.command_op(touch_command[47:40]),.command_object(touch_command[39:32]),.command_value(touch_command[31:0]),
 .command_done(touch_done),.command_code(touch_response[39:32]),.command_result(touch_response[31:0]),
 .crc_errors(touch_crc),.framing_errors(touch_framing),.busy_drops(touch_busy),.session_id(touch_session),.text_address(caption_text_address),.text_data(caption_text_data));
wire service_valid,service_done,local_valid,local_ready;wire [47:0] service_command,local_command;wire [39:0] service_response;wire [15:0] key_drops;
b_command_arbiter inputs(.clk(clk),.rst(rst_net),.touch_valid(touch_valid),.touch_command(touch_command),.touch_done(touch_done),.touch_response(touch_response),
 .local_valid(local_valid),.local_command(local_command),.local_ready(local_ready),.service_valid(service_valid),.service_command(service_command),.service_done(service_done),.service_response(service_response));
b_local_controls keys(.clk(clk),.rst(rst_net),.keys_n({key2,key_period,key1}),.switches(switches[1:0]),.desired(b_desired),.applied(applied_state),.remote(remote_state),
 .list_count(list_count),.ready(local_ready),.valid(local_valid),.command(local_command),.drops(key_drops));
wire [23:0] card_status_net;wire card_status_update;
b_state_mailbox #(.WIDTH(24)) card_status(.source_clk(sd_card_clk),.source_rst(rst_sd),.update(1'b1),.data({native_error,loader_error,native_retries}),
 .dest_clk(clk),.dest_rst(rst_net),.valid(card_status_update),.received(card_status_net));
wire select_b=service_command[39:36]==4'h3;
wire select_diag=service_command[47:40]==1 && (service_command[39:32]==0 || service_command[39:36]==4'he);
wire select_caption=service_command[39:32]>=8'h40 && service_command[39:32]<=8'h45;
wire b_done,a_done,caption_done;wire [39:0] b_response,a_response,caption_response;
wire glyph_valid,glyph_ready,glyph_done;wire [47:0] glyph_command;wire [39:0] glyph_response;
wire host_valid,host_done,host_cancel;wire [47:0] host_command;wire [39:0] host_response;
wire custom_frame;wire [9:0] custom_address;wire [31:0] custom_bits;
wire [5:0] custom_count;wire [15:0] custom_epoch,custom_serial;wire [8:0] custom_settings;
wire custom_visible=custom_epoch!=0 && custom_settings[0] && custom_count!=0;
wire list_edit,list_done,list_ready,list_busy;wire [2:0] list_op,list_count,video_list_count;
wire [3:0] list_value;wire [7:0] list_code;wire [11:0] list_order,video_list_order;
wire [31:0] list_revision,video_list_revision;wire video_qr_valid,qr_pixel;wire [10:0] qr_address;
b_visit_list itinerary(.clk(clk),.rst(rst_net),.edit_valid(list_edit),.edit_op(list_op),.edit_value(list_value),
 .edit_done(list_done),.edit_code(list_code),.order(list_order),.count(list_count),.revision(list_revision),.generating(list_busy),.qr_ready(list_ready),
 .video_clk(video_clk),.video_rst(rst_video),.frame_request(frame_request),.video_order(video_list_order),.video_count(video_list_count),
 .video_revision(video_list_revision),.video_qr_valid(video_qr_valid),.qr_read_address(qr_address),.qr_pixel(qr_pixel));
wire [67:0] b_desired;reg [67:0] b_desired_d;
reg diag_done;reg [39:0] diag_response;
assign service_done=b_done || a_done || diag_done || caption_done;
assign service_response=caption_done?caption_response:diag_done?diag_response:b_done?b_response:a_response;
always @(posedge clk or posedge rst_net)begin
 if(rst_net)begin diag_done<=0;diag_response<=0;b_desired_d<=0;end
 else begin
  b_desired_d<=b_desired;diag_done<=0;
  if(service_valid && select_diag)begin
   diag_done<=1;diag_response<=0;
   if(service_command[31:0]!=0)diag_response<={8'd2,32'd0};
   else case(service_command[39:32])
    8'h00:diag_response<={8'd0,32'h00020006};
    8'he0:diag_response<={8'd0,20'd0,rx_delay_enabled,network_phy_addr,network_mdio_fault,remote_stale,network_peer,network_link,network_found,network_arm[1]};
    8'he1:diag_response<={8'd0,network_phy_id};
    8'he2:diag_response<={8'd0,network_tx_count};
    8'he3:diag_response<={8'd0,network_rx_count};
    8'he4:diag_response<={8'd0,network_errors};
    8'he5:diag_response<={8'd0,network_retries};
    8'he6:diag_response<={8'd0,16'd0,touch_session};
    8'he7:diag_response<={8'd0,24'd0,card_status_net[23:20],card_status_net[19:16]};
    8'he8:diag_response<={8'd0,16'd0,card_status_net[15:0]};
    8'he9:diag_response<={8'd0,16'd0,key_drops};
    8'hea:diag_response<={8'd0,32'h42420075};
    8'heb:diag_response<={8'd0,network_overflow,network_bad};
    8'hec:diag_response<={8'd0,network_reject};
    default:diag_response<={8'd3,32'd0};
   endcase
  end
 end
end
hmi_b_service #(.CLK_HZ(50000000)) touch_b(.clk(clk),.rst(rst_net),
 .valid(service_valid && select_b && !select_diag),.command(service_command),.done(b_done),.response(b_response),
 .applied_state(applied_state),.phy_link(1'b1),.peer_online(1'b1),.stale(1'b0),.desired_control(b_desired),.list_edit(list_edit),.list_op(list_op),.list_value(list_value),.list_done(list_done),.list_code(list_code),
 .list_order(list_order),.list_count(list_count),.list_ready(list_ready),.list_busy(list_busy),.list_revision(list_revision));
bq_caption_controller #(.FONT_BASE_LBA(32'd71041)) captions(.clk(clk),.rst(rst_net),
 .valid(service_valid && select_caption),.command(service_command),.done(caption_done),.response(caption_response),
 .text_address(caption_text_address),.text_data(caption_text_data),.remote_online(network_peer && !remote_stale),
 .remote_valid(glyph_valid),.remote_command(glyph_command),.remote_ready(glyph_ready),.remote_done(glyph_done),.remote_response(glyph_response),
 .sector_request(font_request),.sector_lba(font_lba),.sector_done(font_sector_done),.sector_error(font_sector_error),
 .byte_address(font_byte_address),.byte_data(font_byte_data),.video_clk(video_clk),.video_rst(rst_video),.frame_start(custom_frame),
 .row_address(custom_address),.row_bits(custom_bits),.visible_count(custom_count),.visible_epoch(custom_epoch),
 .display_serial(custom_serial),.visible_settings(custom_settings));
bq_caption_rpc_arbiter rpc_priority(.clk(clk),.rst(rst_net),
 .user_valid(service_valid && !select_b && !select_diag && !select_caption),.user_command(service_command),.user_done(a_done),.user_response(a_response),
 .glyph_valid(glyph_valid),.glyph_command(glyph_command),.glyph_ready(glyph_ready),.glyph_done(glyph_done),.glyph_response(glyph_response),
 .host_valid(host_valid),.host_command(host_command),.host_done(host_done),.host_response(host_response),.host_cancel(host_cancel));
bq_control_host #(.CANCEL_ENABLE(1)) control_host(.clk(clk),.rst(rst_net),.online(network_peer && !remote_stale),.session(touch_session),
 .valid(host_valid),.command(host_command),.done(host_done),.response(host_response),.cancel(host_cancel),
 .request_state(controller_request),.request_commit(controller_commit),.result_state(remote_state[67:0]),.result_update(remote_update));
// The upper 60 bits belong to A's actual media. All view controls are local B.
wire [127:0] desired_scene={remote_state[127:68],b_desired};
wire scene_update=remote_update || b_desired!=b_desired_d;
wire cover_busy;
b_scene_control #(.COVER_ENABLE(1)) control(.net_clk(clk),.net_rst(rst_net),.remote_update(scene_update),.remote_stale(remote_stale),.remote_state(desired_scene),.transition_busy(cover_busy),
 .applied_state(applied_state),.applied_update(applied_update),.sd_clk(sd_card_clk),.sd_rst(rst_sd),.video_clk(video_clk),.video_rst(rst_video),.frame_request(frame_request),
 .map_valid(map_valid),.photo_valid(photo_valid),.photo_bank(photo_bank),.photo_asset(photo_asset),.photo_width(photo_width),.photo_height(photo_height),.local_error(native_error!=0 ? 4'he:loader_error),.desired_asset(desired_asset),.display_ack(display_ack),.protected_bank(protected_bank),
 .video_state(scene),.video_map_valid(video_map_valid),.video_photo_valid(video_photo_valid),.video_photo_bank(video_photo_bank),.animation_ms(animation_ms),.video_photo_width(video_photo_width),.video_photo_height(video_photo_height));
wire hs1,vs1,de1;wire [23:0] rgb1;wire [10:0] x1;wire [9:0] y1;wire [15:0] underruns;
b_scene_display scene_renderer(.mem_clk(ext_mem_clk),.pixel_clk(video_clk),.rst_mem(rst_mem),.rst_pixel(rst_video),
 .init_done(init_done),.refresh(refresh),.busy(mem_busy),.writer_busy(writer_busy),.read_valid(mem_read_valid),.read_data(read_data),.read_enable(mem_read),.read_address(read_addr),.reader_busy(reader_busy),
 .hs(hs0),.vs(vs0),.de(de0),.valid(scene[67:66]==1?video_photo_valid:video_map_valid),.page(scene[67:66]),.bank(scene[67:66]==1?video_photo_bank:2'd0),
 .native_width(video_photo_width),.native_height(video_photo_height),.out_hs(hs1),.out_vs(vs1),.out_de(de1),.out_rgb(rgb1),.out_x(x1),.out_y(y1),.underruns(underruns),.cover_busy(cover_busy));
wire packed_valid,fifo_ready;wire [31:0] packed_data;
rgb565_pack packer(.clk(sd_card_clk),.rst(rst_sd),.frame_reset(write_req || write_ack),.valid(pixel_valid),.rgb(pixel),.ready(fifo_ready),.input_ready(write_ready),.out_valid(packed_valid),.data(packed_data));
frame_read_write #(.BURST_SIZE(128),.EXTERNAL_READER(1),.WRITE_V_FLIP(1),.FRAME_WIDTH(640),.FRAME_HEIGHT(720)) writer(
 .mem_clk(ext_mem_clk),.rst(rst_mem),.Sdr_init_done(init_done),.Sdr_init_ref_vld(refresh),.Sdr_busy(mem_busy),.external_reader_busy(reader_busy),.writer_busy(writer_busy),
 .App_rd_en(),.App_rd_addr(),.Sdr_rd_en(mem_read_valid),.Sdr_rd_dout(read_data),.read_clk(video_clk),.read_req(1'b0),.read_req_ack(),.read_finish(),
 .read_addr_0(21'd0),.read_addr_1(21'd460800),.read_addr_2(21'd921600),.read_addr_3(21'd1382400),.read_addr_index(2'd0),.read_len(21'd460800),.read_en(1'b0),.read_data(),
 .App_wr_en(mem_write),.App_wr_addr(write_addr),.App_wr_din(write_data),.App_wr_dm(write_mask),.write_clk(sd_card_clk),.write_req(write_req),.write_req_ack(write_ack),.write_finish(frame_write_finish),
 .write_addr_0(21'd0),.write_addr_1(21'd460800),.write_addr_2(21'd921600),.write_addr_3(21'd1382400),.write_addr_index(write_bank),.write_len(21'd460800),.write_en(packed_valid),.write_ready(fifo_ready),.write_data(packed_data));
sdram memory(.Clk(ext_mem_clk),.Clk_sft(ext_mem_clk_sft),.Rst(rst_mem),.Sdr_init_done(init_done),.Sdr_init_ref_vld(refresh),.Sdr_busy(mem_busy),
 .App_wr_en(mem_write),.App_wr_addr(write_addr),.App_wr_dm(write_mask),.App_wr_din(write_data),.App_rd_en(mem_read),.App_rd_addr(read_addr),.Sdr_rd_en(mem_read_valid),.Sdr_rd_dout(read_data));
wire [13:0] map_address;wire [15:0] photo_address;wire [7:0] map_pixel,photo_pixel;
b_runtime_thumbnails thumbnail(.load_clk(sd_card_clk),.pixel_clk(video_clk),.rst(rst_sd),.frame_reset(write_req || write_ack),.pixel_valid(pixel_valid),.load_bank(write_bank),.rgb(pixel),.load_asset(loading_asset),.load_complete(asset_complete),.pinned_valid(pinned_valid),
 .map_address(map_address),.map_pixel(map_pixel),.photo_address(photo_address),.photo_pixel(photo_pixel));
wire map_hs,map_vs,map_de;wire [23:0] map_rgb;
wire final_hs,final_vs,final_de,guide_hs,guide_vs,guide_de;wire [23:0] final_rgb,guide_rgb;
b_map_overlay overlay(.clk(video_clk),.rst(rst_video),.hs(hs1),.vs(vs1),.de(de1),.x(x1),.y(y1),.rgb(rgb1),.media_ms(scene[111:80]),
 .poi(scene[71:68]),.movie(scene[78]),.paused(scene[79]),.depth_mode(scene[67:66]!=0),.map_valid(video_map_valid),.photo_valid(scene[71:68]>=1 && scene[71:68]<=4 && pinned_video[scene[69:68]-2'd1]),.photo_bank(scene[69:68]-2'd1),.yaw(8'sd0),
 .map_address(),.map_pixel(map_pixel),.photo_address(photo_address),.photo_pixel(photo_pixel),.out_hs(map_hs),.out_vs(map_vs),.out_de(map_de),.out_rgb(map_rgb));
reg [43:0] map_x;reg [39:0] map_y;
always @(posedge video_clk)begin map_x<={map_x[32:0],x1};map_y<={map_y[29:0],y1};end
b_guide_overlay #(.RUNTIME_CAPTION(1)) guide(.clk(video_clk),.rst(rst_video),.hs(map_hs),.vs(map_vs),.de(map_de),.x(map_x[43:33]),.y(map_y[39:30]),.rgb(map_rgb),
 .page(scene[67:66]),.poi(scene[71:68]),.photo_id(scene[75:72]),.free_view(scene[65]),.paused(scene[79]),.map_valid(video_map_valid),.caption_banner(custom_visible),
 .list_order(video_list_order),.list_count(video_list_count),.qr_valid(video_qr_valid),.qr_address(qr_address),.qr_pixel(qr_pixel),.map_address(map_address),.map_pixel(map_pixel),
 .out_hs(guide_hs),.out_vs(guide_vs),.out_de(guide_de),.out_rgb(guide_rgb));
// Use the existing title band; preserve map, photos, itinerary and QR pixels.
bq_caption_overlay #(.DYNAMIC_Y(1)) custom_overlay(.clk(video_clk),.rst(rst_video),
 .hs(guide_hs),.vs(guide_vs),.de(guide_de),.rgb(guide_rgb),.enabled(custom_visible),
 .scrolling(custom_settings[2:1]!=0),.paused(!scene[65] && scene[79]),.speed(custom_settings[8:3]),
 .char_count(custom_count),.epoch(custom_serial),.position_y(scene[67:66]==0?10'd664:10'd24),
 .frame_start(custom_frame),.row_address(custom_address),.row_bits(custom_bits),
 .out_hs(final_hs),.out_vs(final_vs),.out_de(final_de),.out_rgb(final_rgb));
assign seg_sel=6'b111110;
assign seg_data=(native_error!=0 || loader_error!=0)?8'b10000110:video_map_valid?8'b10000011:8'b11000111;
wire axis_s_user,axis_s_valid,axis_s_last,axis_s_ready,edid_trig,edid_valid;wire [23:0] axis_s_data;wire [7:0] edid_data;
wire [9:0] tmds_ch0_data,tmds_ch1_data,tmds_ch2_data,tmds_clk_data;
video_rgb_to_axis_640x480 u_video_rgb_to_axis_640x480(
    .I_clk         (video_clk),
    .I_rst         (rst_video),
    .I_vs          (final_vs),
    .I_de          (final_de),
    .I_rgb         (final_rgb),
    .O_video_user  (axis_s_user),
    .O_video_valid (axis_s_valid),
    .O_video_last  (axis_s_last),
    .O_video_data  (axis_s_data)
);

// 上电后自动打一拍，触发一次 EDID 读取
startup_pulse #(
    .CNT_MAX(20'd100000)
) u_startup_pulse (
    .I_clk   (video_clk),
    .I_rst   (rst_video),
    .O_pulse (edid_trig)
);

// ===================== HDMI 1.4b 发射 =====================
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE                 ( "EG"       ),
    .HTOTAL                 ( 1650 ),
    .HSA                    ( 40 ),
    .HFP                    ( 110 ),
    .HBP                    ( 220 ),
    .HACTIVE                ( 1280 ),
    .VTOTAL                 ( 750 ),
    .VSA                    ( 5 ),
    .VFP                    ( 5 ),
    .VBP                    ( 20 ),
    .VACTIVE                ( 720 ),
    .VIDEO_VIC              ( 4 ),
    .VIDEO_TPG              ( "Disable"  ),
    .VIDEO_FORMAT           ( "RGB"      ),
    .AUDIO_SAMPLE_RATE      ( "48K"      ),
    .IIC_SCL_DIV            ( 742 )
) u_hdmi_1_4b_transmitter_core_wrapper(
    .I_pixel_clk        (video_clk),
    .I_rst              (rst_video),
    .I_edid_read_trig   (edid_trig),
    .O_edid_read_valid  (edid_valid),
    .O_edid_read_data   (edid_data),

    .I_axis_s_user      (axis_s_user),
    .I_axis_s_valid     (axis_s_valid),
    .I_axis_s_last      (axis_s_last),
    .I_axis_s_data      (axis_s_data),
    .O_axis_s_ready     (axis_s_ready),

    .I_audio_valid      (1'b0),
    .I_audio_left_data  (24'd0),
    .I_audio_right_data (24'd0),
    .I_acr_valid        (1'b0),
    .I_acr_cts          (20'd0),
    .I_acr_n            (20'd0),

    .O_video_locked     (),
    .O_ddc_scl          (HDMI_DDC_SCL),
    .IO_ddc_sda         (HDMI_DDC_SDA),

    .O_ch0_tmds_data    (tmds_ch0_data),
    .O_ch1_tmds_data    (tmds_ch1_data),
    .O_ch2_tmds_data    (tmds_ch2_data),
    .O_clk_tmds_data    (tmds_clk_data)
);

hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi2phy_wrapper(
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (rst_video),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);


endmodule
