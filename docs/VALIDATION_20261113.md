# MATLAB 上位机接入 40GbE：本地验收记录

日期：2026-11-13。对象：本项目 `host/` 中的 MATLAB 上位机及其 Python UDP 后端。

**结论：本地接入与离线验收通过，尚未上板验证。** 本轮没有连接板卡或 hw_server，没有执行初始化、烧写、复位和 FPGA 实现。所有测试网络流量仅在 `127.0.0.1` 上。

## 本次改动

升级版 MATLAB 界面通过异步文件 IPC 调用持久 Python 后端，复用交付包的 `awg_eth` 协议客户端。波形下载、播放控制、ADC 回采使用 QSFP 40GbE UDP 9100。JTAG 保留用于 bit 下载、时钟与 RFDC/MTS 初始化及恢复；普通下载和回采不经过 JTAG。

本次复用交付的 D3C bit 与 F1 固件，没有修改 RTL 或固件。DAC 参数改为 9.8 GS/s、每路 32..131072 点且 32 点对齐；ADC 参数改为 5 GS/s、每路 24..65520 点且 24 点对齐。导出数据为 int16 容器中的 14 bit 左对齐码值，饱和范围 -32768..32764。GUI 不执行重采样。

连接时，后端先只读核对 INFO ID、BUILD、寄存器 ID、ABI、DAC/ADC 采样率与 RAM 容量；不匹配则关闭连接并拒绝写操作。支持非连续通道映射、可选下载 CRC、请求对应的进度显示、异常后的 Busy 释放，以及 CSV/JSON/MAT 回采记录。

回采点数实际传给硬件协议，返回点数不等于请求时拒绝导出。回采导入校验形状、采样率、通道掩码与元数据点数。原始 ADC 实数记录与历史 I/Q 演示记录保留各自采样率；演示显示“模拟数据”。

初始化按钮需用户确认后才调用配套 `program.tcl`。构造界面不会启动硬件工具或连接网络。测试为 GUI 与 Bridge 指定独立 DataRoot，输出不写入正常 `host/app_data/`。

## Python 验收

环境：Windows、Python 3.13。结果：**24 项通过，0 失败，约 5.11 秒**。

覆盖范围：

- 协议编解码、读写语义、错误状态与地址信息。
- 8 路 × 131072 点下载、独立 CRC 参考、丢包与重复包恢复。
- 回采格式、过期 armed 状态恢复、越界读、abort。
- GUI 文件 IPC 连接、状态读取、断开，以及 CRC 开关、点数、通道、进度的传递。
- BUILD/ABI/采样率不符时拒绝连接，且没有发生写操作。
- 非法 run 参数在下载前拒绝；回采实际点数不符时拒绝导出。
- UTF-8 字段、畸形 IPC 拒绝、Windows 读锁期间原子替换重试；进度文件失败不会中断传输任务。

从项目根目录运行：

```powershell
$env:PYTHONPATH=(Resolve-Path host/tools).Path
py -3 -X utf8 -m pytest host/tools/awg_eth/tests -q
```

## MATLAB 与生产后端联调

环境：MATLAB R2023b、生产 Python 后端、本地 UDP 模拟器。最新完整运行退出码为 0，输出 `PASS ALL`。

覆盖范围：

- 构造无硬件副作用；DAC/ADC 默认参数正确。
- 满量程量化、14 bit 左对齐、9.8 GS/s 导出元数据。
- CH2/CH7 非连续通道的每路 131072 点下载，CRC 与请求对应的 CH7 进度。
- 24 点手动触发回采、CSV/MAT 重新导入、非法元数据拒绝。
- 8 路 × 65520 点播放触发回采；8 路选择按钮回调。
- 可选 CRC、一键下载并采集、start/stop/clear、只采集流程。
- 后端异常传播、Busy 释放、恢复、断开；不兼容固件及 RF 未就绪时的控制状态。
- 原生 MATLAB 组件渲染与 `exportapp` 截图；底栏数据说明不遮挡时域或频谱图，模拟记录有明确标记。

从项目根目录的 MATLAB 运行：

```matlab
addpath('host/matlab');
test_awg_eth_app;
```

这些结果证明 GUI、文件 IPC 和生产 UDP 客户端在本地模拟器上的协作。截图由真实 MATLAB 生成，但数据来自模拟器，不能作为 ADC 硬件采集证据。未取得独立原生窗口截图作为额外显示证据。

## 工程迁移与原文件保护

本项目在独立目录整合三类来源：升级版 MATLAB 界面、2026-11-12 40GbE 交付工程、该交付的独立脚本 API。原 ZIP、原解压目录、旧 PS 千兆候选、原 JTAG 界面与现役运行目录保留。

迁移检查结果：

- 初始复制的 FPGA 工程及交付报告共 1846 个文件，逐个 SHA256 一致。随后仅有两处已记录调整：原工程 `AGENTS.md` 归入来源说明并改用当前入口；`script_api/example_matlab.m` 对齐交付包 `06_script_api`。另补入 API 示例数据 `capture_matlab.csv`。
- 原工程规则保存在 [SOURCE_AGENTS_20261112.md](SOURCE_AGENTS_20261112.md)，不作为当前工程的操作授权。
- 配套发布目录 `SHA256SUMS.txt` 的 8 项全部匹配，包括 bit、XSA、ELF 和初始化脚本。
- 迁移后 XPR 的 60 个显式 `File Path` 引用全部存在，且全部位于本项目中。本机没有启动 Vivado 打开或重新构建该工程；交付说明中的“588 文件全找到”属于交付方验证，不能替代本机静态检查。
- 原开发目录与现役运行目录的 `AWGScopeApp.m`、`AWGBridge.m`、`awg_hw.tcl`、`awg_gui_bridge.tcl` 共 8 个保护文件，收尾 SHA256 与修改前一致。
- 工程必要依赖保留在 `fpga/build/`；本次未重新实现或产生新 bit。
- 最大正式文件约 36.75 MiB，没有超过 100 MiB 的单文件。测试输出、截图、复制清单与日志保存在根目录 `过程文件/`，不进入 Git。

日常 GUI 入口是 [host/Start_AWG_Scope.cmd](../host/Start_AWG_Scope.cmd)。`fpga/` 中历史 GUI 只保留为交付来源；完整结构和维护职责见 [README.md](../README.md)。本地 Git 用于保存整合结果；远端仓库尚未创建或推送。

## 尚未验证

本机尚未验证真实光口、网卡/MTU/ARP、板卡初始化路径、现成 bit 与升级界面的端到端配合、实际 DAC 播放与 ADC 回采、长时间稳定性及真实速度。下一步需要获准占用板卡后做实机联调。

交付说明所载“8 路下载含 CRC 0.16 秒、8 路读回约 40 毫秒”为交付机历史报告，本轮未复测。GUI 的速度显示统计有效样点数据和整个操作耗时，不能直接解释为 40GbE 裸链路吞吐。
