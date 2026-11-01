
# ============================================================
# merged_top_tf_hdmi_audio.sdc
# 用于：TF 图片轮播 + HDMI(视频+音频) 整合工程
#
# 合并原则：
# 1) 保留 top.sdc 里的系统主时钟与 derive_clocks
# 2) 把 timing(2).sdc 里的 pixel/serial 时钟改成整合工程实际名字
# 3) 增加 hdmi_5x_clk / audio_mclk 的命名
# 4) 不再对内部 net 直接 create_clock，避免和 derive_clocks 重复
# ============================================================

# ------------------------------------------------------------
# 1. 板级输入主时钟
#    你的原 top.sdc 里 clk=50MHz，所以这里仍然用 20ns
# ------------------------------------------------------------
create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]

# ------------------------------------------------------------
# 2. 自动推导 PLL 输出时钟
# ------------------------------------------------------------
derive_clocks

# ------------------------------------------------------------
# 3. 给关键 PLL 输出命名
#    下面这些路径是按你当前工程实例名写的：
#      sys_pll      -> sys_pll_m0
#      video_pll    -> video_pll_m0
#      音频 PLL     -> u_audio_pll
#
#    如果综合后实例路径略有不同，就按 Timing Analyzer 里的实际 pin 路径改。
# ------------------------------------------------------------
rename_clock -name {sd_card_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[0]}]
rename_clock -name {ext_mem_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[1]}]
rename_clock -name {video_clk}   -source [get_ports {clk}] -master_clock {clk} [get_pins {video_pll_m0/pll_inst.clkc[0]}]
rename_clock -name {hdmi_5x_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {video_pll_m0/pll_inst.clkc[1]}]


# Pixel and serializer clocks run simultaneously. Do not mark them exclusive.
# I/O delays remain uncharacterized: timing closure is NOT established.

# R5 pixel PLL is 89/60 of the board clock (NOCOMP VCO 1112.5 MHz / 15).
# The media/memory clocks and
# pixel clock communicate through synchronizers, stable request/ack bundles,
# or independent dual-port RAM ports. Constrain physical CDC propagation,
# not the arbitrarily small phase separation of unrelated capture events.
# 9.7 ns is below one fastest source/destination period (10 ns).
# Every selected crossing retains a routed maximum delay. TD datapath_only
# suppresses minimum checks on those asynchronous crossings (SWUG200 p30).
# Native intra-domain paths and pixel-to-serializer timing remain unchanged.
# Review/CDC inventory: docs/R5跨时钟与时序说明.md.
set_max_delay -from [get_clocks {sd_card_clk}] -to [get_clocks {video_clk}] 9.7 -datapath_only
set_max_delay -from [get_clocks {video_clk}] -to [get_clocks {sd_card_clk}] 9.7 -datapath_only
set_max_delay -from [get_clocks {ext_mem_clk}] -to [get_clocks {video_clk}] 9.7 -datapath_only
set_max_delay -from [get_clocks {video_clk}] -to [get_clocks {ext_mem_clk}] 9.7 -datapath_only
set_max_delay -from [get_clocks {clk}] -to [get_clocks {video_clk}] 9.7 -datapath_only
set_max_delay -from [get_clocks {video_clk}] -to [get_clocks {clk}] 9.7 -datapath_only

# Internal/cross-domain additions, assuming wrapper instance u_network and clk=50M.
# If the integration instance name differs, replace it, then reject unmatched paths.
create_clock -name net_rx_clk -period 8 -waveform {0 4} [get_ports {phy_rxc}]
rename_clock -name {net_tx_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {u_network/net_pll/pll_inst.clkc[0]}]
create_generated_clock -name net_txc_out -source [get_pins {u_network/net_pll/pll_inst.clkc[0]}] -master_clock {net_tx_clk} -divide_by 1 [get_ports {phy_txc}]
# Stable-bundle req/ack and three-stage synchronizers: constrain actual CDC
# propagation instead of removing every path between these domains.
set_max_delay -from [get_clocks {net_rx_clk}] -to [get_clocks {clk}] 19 -datapath_only
set_max_delay -from [get_clocks {clk}] -to [get_clocks {net_rx_clk}] 19 -datapath_only
# TX is 125MHz from a dedicated PLL; only the held req/ack bundles below use CDC bounds.
# External RGMII IO delays MUST be added from confirmed PHY TXDLY/RXDLY and PCB
# skew in both edge directions. Omission is an open timing-signoff item, NOT pass.
# MDIO remains open-drain; also verify input thresholds and MDC/MDIO timing.

# compact mailbox: data remains in source producer until final consumption.
# The three-stage req/ack synchronizers cover bundle settling and backpressure.
# Constrain propagation, not fictitious same-edge capture; all other paths retain STA.
# get_regs uses RTL variable names, NOT synthesized *_reg cell-name patterns.
set_max_delay -from [get_regs -hier {u_network/tx_mailbox/request*}] -to [get_regs -hier {u_network/tx_mailbox/req_sync*}] 19 -datapath_only
set_max_delay -from [get_regs -hier {u_network/tx_mailbox/ack}] -to [get_regs -hier {u_network/tx_mailbox/ack_sync*}] 19 -datapath_only

# Network reset_tx is a three-stage asynchronous-assert/synchronous-release chain.
# Board reset may deassert at any TX phase; only these synchronizer entry resets
# waive synchronous recovery/removal and retain a 19ns physical bound. The chain
# output to all downstream TX logic still receives ordinary TX-domain STA.
set_max_delay -from [get_clocks {clk}] -to [get_regs -hier {u_network/reset_tx/release_sync*}] 19 -datapath_only

# Compact-state packet fields come from exactly these three stable producer registers.
set_max_delay -from [get_regs -hier {u_network/state_link/tx_image*}] -to [get_regs -hier {u_network/mac_tx/octet_q*}] 19 -datapath_only
set_max_delay -from [get_regs -hier {u_network/state_link/pending_state*}] -to [get_regs -hier {u_network/mac_tx/octet_q*}] 19 -datapath_only
set_max_delay -from [get_regs -hier {u_network/state_link/sequence_no*}] -to [get_regs -hier {u_network/mac_tx/octet_q*}] 19 -datapath_only

# Audited request-bundle CDC only. No entire-clock-pair exception.
# mode and bank are stable before the 3-stage request reaches ACK; the writer
# samples these fields only during ACK, while source waits for synchronized ACK.
# Mode changes reset all media domains for 2ms before new requests are released.
set_max_delay -from [get_clocks {sd_card_clk}] -to [get_regs -hier {frame_read_write_m0/frame_fifo_write_m0/request_base[*]}] 9.7 -datapath_only
set_max_delay -from [get_clocks {sd_card_clk}] -to [get_regs -hier {frame_read_write_m0/frame_fifo_write_m0/request_length[*]}] 9.7 -datapath_only
# First synchronizer stage only; subsequent same-domain stages remain normal STA.
set_max_delay -from [get_clocks {sd_card_clk}] -to [get_regs -hier {frame_read_write_m0/frame_fifo_write_m0/req_sync[0]}] 9.7 -datapath_only
set_max_delay -from [get_regs -hier {frame_read_write_m0/frame_fifo_write_m0/write_req_ack}] -to [get_regs -hier {frame_read_write_m0/write_ack_sync[0]}] 9.7 -datapath_only
set_max_delay -from [get_regs -hier {frame_write_toggle_mem}] -to [get_regs -hier {movie/player/finish_sync[0]}] 9.7 -datapath_only
set_max_delay -from [get_regs -hier {frame_write_toggle_mem}] -to [get_regs -hier {library_mode$library_player/finish_sync[0]}] 9.7 -datapath_only
# The FIFO's own .tcl already bounds registered Gray pointers to first sync stage
# at 9.7ns. Do not duplicate or widen that scoped IP constraint.

# A013: request offset is a held bundle captured ahead of ACK.
set_max_delay -from [get_clocks {sd_card_clk}] -to [get_regs -hier {frame_read_write_m0/frame_fifo_write_m0/request_offset[*]}] 9.7 -datapath_only

# reset_release: asynchronous assertion, three-clock local release.
# TD replicates the final pipe register under unrelated packed cell names.
# A register-name endpoint filter misses some SR replicas. Bound ONLY paths
# from the two board-domain reset producers through their shared async reset
# net into SD/memory domains. This net drives reset_release entry SR pins;
# downstream local reset distribution and all ordinary data retain normal STA.
# No false path is added. 9.7ns is below both destination clock periods.
set_max_delay -from [get_regs -hier {hmi_restart_active}] -through [get_nets -hier {reset_mem/arst}] -to [get_clocks {sd_card_clk ext_mem_clk}] 9.7 -datapath_only
set_max_delay -from [get_regs -hier {rst_all_reg}] -through [get_nets -hier {reset_mem/arst}] -to [get_clocks {sd_card_clk ext_mem_clk}] 9.7 -datapath_only

# Held boot mode enters explicit two-stage synchronizers.
set_max_delay -from [get_regs -hier {movie_mode_boot}] -to [get_regs -hier {mode_sd_sync*}] 9.7 -datapath_only
# held chapter metadata, two local stages, 2 ms reset settling.
# Bound only the first SD synchronizer stage; the second keeps normal STA.
set_max_delay -from [get_regs -hier {chapter_boot*}] -to [get_regs -hier {chapter_sd_meta*}] 9.7 -datapath_only

# Serializer contains its own three-stage reset_release in lane_lvds_10_1.
# Only link reset through hmi_rst_video into serializer reset-entry SRs is async.
# TD datapath_only retains <=2.3ns propagation and suppresses entry removal;
# synchronizer output-to-consumer recovery/removal and pixel data are normal STA.
# exactly three entry SR endpoints, no data path.
set_max_delay -from [get_clocks {video_clk}] -through [get_nets -hier {hmi_rst_video}] -to [get_clocks {hdmi_5x_clk}] 2.3 -datapath_only
