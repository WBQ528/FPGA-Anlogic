# 运行介质

完整RAR中的A.img和B.img为分别对应A媒体板、B导览板的FAT16镜像，容量分别为1GiB和128MiB。源码仓库不存放这两项大文件，请从本仓库Release下载完整RAR。

文件清单见files.json：A卡11项，含八张BMP、HXV视频、讲解PCM和图片配乐HXA；B卡14项，含地图、十二张园区BMP及中文字库。镜像内容与最终固件配套，不需要PC在线生成路线或二维码。

镜像整体SHA-256：

- A.img：882a03ff680a087e537971e78cac0a3b97e4bddc4f952f69007ae607079e6c8c
- B.img：202b8e066f988fa764a14c18648d8ecb2cb88d28f0cd23429fb5f02e1bca19e7

使用写卡工具时确认目标TF设备，写入会覆盖卡内容。根目录SHA256SUMS.txt包含完整RAR解压后各文件校验值，其中两张镜像在普通Git检出中缺省。
