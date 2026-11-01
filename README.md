# 基于FPGA的双屏协同导览系统

基于两块安路HX4S20C（EG4S20BG256）的多媒体展示与互动导览系统。以成都植物园为示范场景，A板负责图片、视频和音频播放，B板负责地图、园区介绍、游览清单及触屏交互，通过千兆以太网协同。

## 功能

- TF资源读取、BMP解析、SDRAM帧缓存和HDMI音视频输出；按键切换、自动轮播与暂停。
- 动态字幕与图层叠加、四种转场、多分辨率缩放、亮度/对比度调节及PCM波形可视化。
- 1280×720、30fps、72秒视频内容，48kHz PCM讲解与同步字幕；A板8张展示图片，B板12张园区图片及地图。
- 串口触屏控制、拼音字幕输入、跨屏章节点播、播放状态回读和游览清单编辑。
- FPGA运行时绘制路线、排版清单、生成二维码；扫码进入携带游览顺序的手机图文导览。

## 工程入口

| 内容 | 路径 |
| --- | --- |
| A板原生TD工程 | [BQ_FPGA_A.al](BQ_FPGA_A/design/td_project/BQ_FPGA_A.al) |
| B板原生TD工程 | [BQ_FPGA_B.al](BQ_FPGA_B/design/td_project/BQ_FPGA_B.al) |
| 串口屏原生工程 | [HMI/project](HMI/project) |
| 串口屏事件程序 | [HMI/src](HMI/src) |
| 最终固件 | [firmware](firmware) |
| 手机导览前端 | [mobile-guide](mobile-guide) |
| 完整运行介质说明 | [media/README.md](media/README.md) |

工程组合为A Final1.2、B Final1.0及配套串口屏。每板有独立8MiB SDRAM和TF卡。媒体处理、图层、控制、路线与二维码核心逻辑均由FPGA执行。

## 文档

- [系统架构](docs/architecture.md)
- [构建与下载](docs/build.md)
- [硬件连接与操作](docs/operation.md)
- [媒体格式与显示规格](docs/media.md)
- [资源与验证范围](docs/implementation.md)
- [第三方组件与素材说明](docs/third-party.md)

源码目录提供工程代码及说明；完整RAR附件同时包含两张TF镜像。文件完整性见[SHA256SUMS.txt](SHA256SUMS.txt)。大镜像不纳入普通Git对象。
