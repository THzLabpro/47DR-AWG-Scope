# 47DR AWG / Scope · 40GbE

使用前阅读 [PROJECT_RULES.md](PROJECT_RULES.md)。本项目将升级版 MATLAB 上位机与 2026-11-12 交付的 D3C / F1 工程整合在一起，下载、播放控制和 ADC 回采均使用 QSFP 40GbE UDP。JTAG 用于下载 bit、时钟与 RFDC/MTS 初始化及故障恢复。

本地接入已经完成，Python 与原生 MATLAB 的回环模拟器测试通过。**这次集成尚未上板验证，也没有测得真实传输速度。** 详细范围见 [本地验收记录](docs/VALIDATION_20261113.md)。

## 启动

双击 [host/Start_AWG_Scope.cmd](host/Start_AWG_Scope.cmd)，或在 MATLAB 中运行 [host/matlab/launch_awg_scope.m](host/matlab/launch_awg_scope.m)。需要 MATLAB（本次验证为 R2023b）和 Python 3.10+；界面的 UDP 后端只使用 Python 标准库。启动界面不会连接板卡。

没有硬件时点击“离线接收演示”，查看带有“模拟数据”标记的历史 I/Q 演示记录。真实 40GbE 回采显示 5 GS/s 原始实数 ADC 样点；演示记录的采样率由其元数据决定。

连接实际板卡前，先确认板卡无人占用且获准操作：

1. 在“连接设置”选择 Python。板卡默认 `192.168.42.2:9100`，每包默认 256 字，适用于普通 MTU。
2. MATLAB 所在电脑应直接连接可达的光口网段，建议网卡 `192.168.42.20/24`。不要使用 `.10`，交付 bit 对该地址绑定了原测试机 MAC。每包改为 2048 字时，需要 MTU 9000。
3. 板卡已初始化时点“② 连接板卡”。界面先只读核对 D3C BUILD、ABI、采样率和 RAM 容量，不匹配就拒绝操作。
4. 首次上电或更换 bit 时，获准后再点“① 初始化板卡”。此操作会复位板卡并调用 XSCT；需要 Vivado/Vitis 2025.2、JTAG 和匹配的 hw_server。
5. 选择 DAC 通道并导入实数波形，下载后播放，再选择 ADC 通道和实际回采点数。“一键下载并采集”可串联这些操作。

GUI 设置、后台日志和采集文件保存在 `host/app_data/`，不进入 Git。断开连接会释放网络后端，**不会停止已运行的 DAC**；需要停播时先点“停止播放”。

## 配套版本与数据

| 项目 | 本项目使用值 |
|---|---|
| FPGA / 初始化固件 | D3C / F1，BUILD `0xD3C02026`，ABI `0x00030001` |
| 传输 | QSFP 40GbE，UDP 9100，沿用交付包 V1 协议 |
| DAC | 9.8 GS/s，8 路，每路 32..131072 点，32 点对齐 |
| ADC | 5 GS/s，8 路，每路 24..65520 点，24 点对齐 |
| 码值 | int16 容器，14 bit 左对齐；满量程量化为 -32768..32764 |
| 校验 | 默认逐通道 CRC，不逐字整波形回读 |
| 回采文件 | CSV + JSON，同时保存可重新导入的 MAT；未选通道在 MAT 中为 NaN |

GUI 不重采样，也不做数字上变频。原来 9 GS/s 的波形需要先在 MATLAB 中重采样为 9.8 GS/s，再导入。MATLAB 中物理 CH0 对应数据矩阵第 1 列；多列波形按选中的 DAC 从小到大对应。

## 目录与维护入口

| 入口 | 用途 |
|---|---|
| [host/matlab/AWGScopeApp.m](host/matlab/AWGScopeApp.m) | 当前 MATLAB 界面，唯一日常 GUI 入口 |
| [host/matlab/AWGBridge.m](host/matlab/AWGBridge.m) | 异步文件 IPC 与持久 Python 进程 |
| [host/tools/awg_eth/gui_bridge.py](host/tools/awg_eth/gui_bridge.py) | GUI 的 40GbE 后端，含固件配套检查 |
| [host/hardware/eth40g_v1_2/](host/hardware/eth40g_v1_2/) | 原样导入的 bit、XSA、ELF、初始化脚本与 SHA256 |
| [fpga/build/D3C_IMPL/vivado/d0_clock_probe.xpr](fpga/build/D3C_IMPL/vivado/d0_clock_probe.xpr) | 完整 Vivado 工程；内部相对路径保持完整 |
| [fpga/doc/00_ETH_PLAN.md](fpga/doc/00_ETH_PLAN.md) | 交付工程的协议与架构说明 |
| [fpga/script_api/README_脚本接口说明.md](fpga/script_api/README_脚本接口说明.md) | 独立 Python / MATLAB 脚本接口 |
| [reports/handoff_20261112/](reports/handoff_20261112/) | 交付机的历史报告，未经本机重新实测 |
| [docs/HANDOFF_README_20261112.md](docs/HANDOFF_README_20261112.md) | 原交付包说明，目录名称与性能数字保留交付时语境 |

`fpga/` 保留交付工程完整结构，包括构建依赖和原来的上位机源码。日常 MATLAB GUI 修改在 `host/`，`fpga/matlab`、`fpga/tools/awg_gui` 只作为交付来源留存。`fpga/build/` 含工程依赖，不能按普通缓存整目录排除。交付包的便携 exe 及其运行库保留在原交付目录，本项目不重复收录。

本项目复用现成 bit，没有修改 RTL 或固件。旧的 PS 千兆 TCP 候选不属于本项目，也没有合并进来；原 JTAG 上位机与运行目录保持原状。

## 离线验证

Python 测试从项目根目录运行；需要 pytest，所有网络交互都只使用 `127.0.0.1`：

```powershell
$env:PYTHONPATH=(Resolve-Path host/tools).Path
py -3 -X utf8 -m pytest host/tools/awg_eth/tests -q
```

MATLAB 测试运行真实界面和生产 Python 后端，但板卡端使用本地 UDP 模拟器：

```matlab
addpath('host/matlab');
test_awg_eth_app;
```

测试临时数据统一写入根目录 `过程文件/`，不写入正常 `host/app_data/`。本地工程已整理，远端仓库尚未创建或推送。
