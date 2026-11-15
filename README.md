# 47DR AWG / Scope · V2.1

本项目只维护一套 **Python / PySide6 V2.1 工作台**。使用者在自己的电脑生成波形、显示和分析数据；实验室电脑运行控制服务，经本机 QSFP 40GbE 完成下载、播放控制和 ADC 回采。也支持在接有光口的电脑上直接控制板卡。执行约定见 [PROJECT_RULES.md](PROJECT_RULES.md)。

当前已完成本机回环模拟验证，**尚未部署到实验室或完成本次集成的实板验证，未测得实际传输速度**。验收范围及源码来源见 [V2.1 本机验收](docs/VALIDATION_20261115.md)。

## 启动工作台

需要 64 位 Python 3.10+，本次测试为 Windows / Python 3.13。从项目根目录安装依赖：

```powershell
py -3 -m pip install -r host/requirements.txt
```

双击 [host/Start_AWG_Scope.cmd](host/Start_AWG_Scope.cmd)。启动不会连接板卡。只用本机模拟器时，可运行 `host\Start_AWG_Scope.cmd --emulator`；窗口标记“模拟器”，此模式仍需点击连接。

默认连接方式为“实验室远程服务”。在“连接设置”填写实验室电脑的 Tailscale 地址和 TCP 4748，不需要额外密码。使用者电脑不需要光口网卡或 hw_server。服务的安装与启动见 [远程控制服务](docs/REMOTE_SERVICE.md)。

实验室电脑直接操作时，选择“本机直连光口”：板卡默认 `192.168.42.2:9100`，批量数据端口 UDP 9101；光口网卡需 MTU 9000，建议 `192.168.42.20/24`，不要使用 `.10`。连接时只读核对固件身份，版本不匹配或批量端口不可用即拒绝访问。

## 日常流程

在本机生成或导入波形后，连接服务并刷新状态；板卡正在播放时，要更换波形必须先手动停止播放。下载可默认校验 CRC 并自动播放。下载、播放控制和单次采集完成后自动释放远程控制权，DAC 继续播放；连续采集停止后释放，当前一帧完成后响应停止。

单次采集读回原始数据后立即释放，再在使用者电脑运行 FFT、测量与显示。用“保存采集数据…”保存 CSV 与同名 JSON，之后用“打开采集记录…”重新分析，不必连接板卡。长采集保留全部原始样点，FFT 与测量最多取开头 262144 点，界面会注明。

设置、日志默认保存在 `host/app_data/`，采集文件由使用者选择保存位置。测试可通过环境变量 `AWG_APP_DATA` 隔离设置和日志。实验数据与本机设置不提交 Git。

## 配套硬件

| 项目 | 当前工作台要求 |
|---|---|
| FPGA / 初始化固件 | D4B BUILD `0xD4B02026`、ABI `0x00050000`、F3 |
| DAC / ADC | 9.8 GS/s / 5 GS/s，8 路 |
| 每路 TX 最大点数 | 1 / 2 / 3–4 / 5–8 路：1048576 / 524288 / 262144 / 131072，32 点对齐 |
| 每路 RX 最大点数 | 1 / 2 / 3–4 / 5–8 路：1966080 / 983040 / 491520 / 245760，24 点对齐 |
| 码值 | int16 容器，14 bit 左对齐，低两位为零 |
| 传输 | 板卡侧 UDP 9100 控制、9101 批量数据；远程侧 TCP 4748 |

V2.1 配套的 D4B/F3 固件已从仓库 V2.1 Release 导入 [host/hardware/eth40g_v2_1/](host/hardware/eth40g_v2_1/)，首次上电初始化时工作台默认使用该目录。已初始化的匹配板卡可直接连接。不能拿仓库里的旧 D3C/F1 包给 V2.1 初始化。JTAG 继续用于初始化和恢复；远程控制服务不执行烧写、复位或 hw_server 操作。

## 维护位置与历史材料

| 位置 | 用途 |
|---|---|
| [host/tools/awg_gui/](host/tools/awg_gui/) | 唯一维护的 GUI、波形生成、导入、显示和本地分析 |
| [host/tools/awg_eth/](host/tools/awg_eth/) | V2.1 光口数据通路、严格版本检查、模拟器与远程服务 |
| [host/hardware/program_v21.tcl](host/hardware/program_v21.tcl) | 从 V2.1 源码导入的初始化脚本，未连接硬件运行 |
| [fpga/](fpga/) | 原 V1/D3C/F1 交付工程、依赖与历史 GUI/API；不代表已取得 F3 工程 |
| [host/matlab/](host/matlab/) | 原 MATLAB 源码历史留存，启动入口已撤下，不再维护 |
| [host/hardware/eth40g_v2_1/](host/hardware/eth40g_v2_1/) | V2.1 D4B/F3 板卡发布包，含固件、脚本和签核报告 |
| [host/hardware/eth40g_v1_2/](host/hardware/eth40g_v1_2/) | 历史 D3C/F1 固件，不能用于当前工作台 |
| [docs/VALIDATION_20261113.md](docs/VALIDATION_20261113.md) | 原 MATLAB 版本的历史本机验收，非当前版本结论 |

原始 ZIP、原 JTAG 工作目录、旧 PS 千兆候选和实验数据保留。当前没有修改 RTL 或重建 bit。`fpga/build/` 包含工程依赖，不应当作缓存整目录删除。

## 离线验证

所有测试网络交互仅使用 `127.0.0.1`；初始化菜单测试使用假的 XSCT 程序，不接 JTAG：

```powershell
$env:PYTHONPATH=(Resolve-Path host/tools).Path
$env:QT_QPA_PLATFORM='offscreen'
$env:AWG_APP_DATA=Join-Path (Get-Location) '过程文件/V2适配/test_app'
py -3 -m pytest host/tools/awg_eth/tests host/tools/awg_gui/tests -q --basetemp '过程文件/V2适配/pytest_run'
```

测试依赖另装 `pytest`。底层测试明确保留了来源代码的 V1 寄存器回归，这不构成第二套工作台或兼容入口。
