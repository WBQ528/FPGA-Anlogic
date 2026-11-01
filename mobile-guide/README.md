# 手机随行图文导览

静态HTML、CSS、JavaScript及JSON数据，不依赖Node安装或构建脚本。将本目录部署到静态站点即可使用；直接通过HTTP访问index.html。

URL参数`r`为园区编号1至4组成的不重复序列，例如`?r=1243`。FPGA二维码携带此序列，前端按序显示游览清单。路线连线仅表示顺序，现场步行按园内道路指引。

当前演示入口：https://wbq528.github.io/FPGA_BQ_guide/ 。代码不会将手机操作传回FPGA，不提供实时定位功能。
