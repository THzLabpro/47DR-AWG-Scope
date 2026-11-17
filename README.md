# 47DR AWG / Scope · V2.1

本项目只维护一套 **Python / PySide6 V2.1 工作台**。使用者在自己的电脑生成波形、显示和分析数据；实验室电脑运行控制服务，经本机 QSFP 40GbE 完成下载、播放控制和 ADC 回采。也支持在接有光口的电脑上直接控制板卡。执行约定见 [PROJECT_RULES.md](PROJECT_RULES.md)。

实验室远程服务已投入使用，已通过 Tailscale 完成实板下载、CRC 校验和 ADC 回采；DAC 0、2、4、6 的单音回环及单子带回采已有实测记录。具体范围和仍待验证的项目见 [远程服务实板验证](docs/VALIDATION_REMOTE_BENCH_20261115.md)；此前的模拟验收见 [V2.1 本机验收](docs/VALIDATION_20261115.md)。

## 启动工作台

### 直接使用客户端（推荐）

在 [v2.1.1 发行页](https://github.com/THzLabpro/47DR-AWG-Scope/releases/tag/shared-clients-v2.1.1) 的 **Assets** 下载所需压缩包。两套客户端在同一个发行页，各自独立运行。

| 用途 | 下载文件 | 完整解压后的入口 |
|---|---|---|
| 47DR 波形下载、播放、ADC 回采 | `47DR_Shared_v2.1.1_win64.zip` | `47DR_Shared/47DR_Shared.exe` |
| RF-UDP 测试、遥测 | `RFUDP_Shared_v2.1.1_win64.zip` | `RFUDP_Shared/RFUDP_Shared.exe` |

复制或移动时保留整个客户端文件夹及其依赖，不单独拿走 exe。打包客户端无需安装 Python、Vivado 或下载 FPGA 工程。发行页中的 `Source code (zip/tar.gz)` 是仓库源码，不是上述可运行客户端。

首次使用先接入实验室 Tailscale 网络，再打开客户端，确认服务地址为 `http://100.121.70.53:4749`，填写自己的姓名并连接。以后会记住设置。连接后可查看使用人和队列，提交下载或测试才申请占用；结束时点“结束使用”或关闭窗口。详细操作及异常处理见[共板使用说明](docs/BOARD_SHARING.md)。

### 已经 git clone / git pull 的用户

本仓库包含 **47DR 上位机与公共调度源码**；`git clone` / `git pull` 不会下载 Release 附件，也不包含 RF-UDP 完整工程。只需要运行 RF-UDP 客户端时，仍从上方发行页下载 `RFUDP_Shared_v2.1.1_win64.zip`。打包输出 `host/dist/` 不是拉取仓库后必有的目录。

需要从源码运行 47DR 时，首次获取仓库：

```powershell
git clone https://github.com/THzLabpro/47DR-AWG-Scope.git
cd 47DR-AWG-Scope
```

已有仓库时，在仓库目录执行 `git pull --ff-only origin main`；如有本地修改或分支分叉，先处理提示，不强制覆盖。

需要 64 位 Python 3.10+，本次测试为 Windows / Python 3.13。从项目根目录安装依赖：

```powershell
py -3 -m pip install -r host/requirements.txt
.\host\Start_AWG_Scope.cmd
```

从源码使用时双击 [host/Start_AWG_Scope.cmd](host/Start_AWG_Scope.cmd)，进入共享模式并读取服务状态，启动不会自动烧写或播放。只用本机模拟器时，可运行 `host\Start_AWG_Scope.cmd --emulator`；窗口标记“模拟器”，此模式仍需点击连接。

双击启动默认进入共享模式，连接 `http://100.121.70.53:4749`，首次填写姓名；原 4748 服务已停用。使用者电脑不需要光口网卡或 hw_server。共板入口见[使用说明](docs/BOARD_SHARING.md)。

实验室电脑直接操作时，选择“本机直连光口”：板卡默认 `192.168.42.2:9100`，批量数据端口 UDP 9101；光口网卡需 MTU 9000，建议 `192.168.42.20/24`，不要使用 `.10`。连接时只读核对固件身份，版本不匹配或批量端口不可用即拒绝访问。

## 日常流程

共板 V2 在[两套上位机内显示使用人和队列](docs/BOARD_SHARING.md)，不需要网页、预计用时或领用文件。共享模式使用 `--shared`：任务按提交内容排队，关闭窗口或结束使用触发服务清理。实验室 v07 服务已配置开机启动，使用 `lab_config_v5.json`；4749 的 47DR 实板初始化、4096 点零波形下载及 CRC 校验、4080 点 ADC 回采通过，RF-UDP 短测数据回环、UDP 遥测接收和 COM6 串口解析已验证。自动交接已启用，已实测正常关窗、运行中关窗和断线超时交接；旧 4748 入口已停用。物理 RF 功率及长期稳定性未验收。详见[本轮验收与限制](docs/BOARD_SHARING_VALIDATION_20261117.md)。

在本机生成或导入波形后，提交下载或采集。有人使用时，界面显示对方姓名；确认排队后，轮到会自动执行已提交的任务。共板模式下，单次任务结束仍保留本场实验占用；完成实验后点“结束使用”或关闭窗口，服务确认停止与清理完成后再交给下一位。

FFT、测量与显示在使用者电脑运行。用“保存采集数据…”保存 CSV 与同名 JSON，之后用“打开采集记录…”重新分析，不必连接板卡。长采集保留全部原始样点，FFT 与测量最多取开头 262144 点，界面会注明。

设置、日志默认保存在 `host/app_data/`，采集文件由使用者选择保存位置。测试可通过环境变量 `AWG_APP_DATA` 隔离设置和日志。实验数据与本机设置不提交 Git。

## 配套硬件

| 项目 | 当前工作台要求 |
|---|---|
| FPGA / 初始化固件 | D4B BUILD `0xD4B02026`、ABI `0x00050000`、F3 |
| DAC / ADC | 9.8 GS/s / 5 GS/s，8 路 |
| 每路 TX 最大点数 | 1 / 2 / 3–4 / 5–8 路：1048576 / 524288 / 262144 / 131072，32 点对齐 |
| 每路 RX 最大点数 | 1 / 2 / 3–4 / 5–8 路：1966080 / 983040 / 491520 / 245760，24 点对齐 |
| 码值 | int16 容器，14 bit 左对齐，低两位为零 |
| 传输 | 47DR 板卡侧 UDP 9100 控制、9101 批量数据；共享客户端侧 HTTP/TCP 4749 |

V2.1 配套的 D4B/F3 固件位于 [host/hardware/eth40g_v2_1/](host/hardware/eth40g_v2_1/)。共板模式由实验室服务加载已登记的匹配固件，使用者电脑无需携带 bit 或 ELF。不能拿旧 D3C/F1 包给 V2.1 初始化。JTAG 用于初始化和恢复；跨工程切换需等待服务完成固件初始化。

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
