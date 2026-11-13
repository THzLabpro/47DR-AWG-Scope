# 47DR AWG / 示波器（40GbE 光口）V1.2 交接包（2026-11-12）

ZU47DR RFSoC 板：DAC 9.8 GS/s × 8 通道循环播放，ADC 5 GS/s × 8 通道采集。波形下载和数据回读都经 QSFP 40GbE 光口（UDP）。
本交接包可以直接拷到其他电脑使用，内容包括：
- 免安装上位机（exe，自带 bit 和初始化文件）；
- 板卡烧写文件；
- 完整工程源码与已构建的 Vivado 工程；
- 上板测试报告。

| 项目 | 值 |
|---|---|
| 版本 | V1.2（git tag `awg-eth-v1.2`，分支 `v1-release`） |
| 位元流 | D3C，BUILD_ID `0xD3C0_2026`，ABI `0x00030001` |
| 固件 | F1（`rf_awg_init.elf`） |
| DAC | 9.8 GS/s，8 × 131072 点，14 bit，URAM |
| ADC | 5 GS/s，8 × 65520 点，14 bit，BRAM |
| 实测 | 8 通道 × 131072 点下载含 CRC 0.16 s；8 通道 × 65520 点读回约 40 ms |

## 目录结构

```
rf_awg_eth_v1_handoff_20261112/
├── 01_board_release/        板卡烧写文件
│   ├── rf_awg_scope_v1.bit  FPGA 位元流（= awg_eth_v2.bit）
│   ├── awg_eth_v2.xsa       硬件导出文件
│   ├── rf_awg_init.elf      PS 初始化固件（LMK、RFDC、MTS）
│   ├── psu_init.tcl         PS 初始化
│   ├── init_protocol.txt    初始化握手地址
│   ├── program.tcl          烧写 + 初始化脚本（XSCT）
│   ├── read_init_trace.tcl  经 JTAG 读初始化日志（串口被占用时用）
│   ├── signoff_reports/     时序、DRC、CDC、资源报告
│   └── SHA256SUMS.txt
├── 02_project/rf_awg_eth_v1/  完整工程
│   ├── rtl/ constraints/ ip/ scripts/ sim/ software/ doc/ tools/
│   ├── build/D3C_IMPL/      已构建的 Vivado 工程（vivado/d0_clock_probe.xpr）与 bit/xsa
│   ├── build/F1/package/    固件包（同 01_board_release）
│   └── reports/             各阶段开发报告
├── 03_results/              上板测试报告（E5、E5C、E6_GUI）与实现报告（D3B/D3C_IMPL、F1）
├── 06_script_api/           纯代码调用的函数（Python + MATLAB），见第 7 节
│   ├── python/awg47dr.py    8 个独立函数
│   ├── matlab/*.m           8 个 .m 文件，一个文件一个函数
│   ├── README_脚本接口说明.md
│   ├── example_python.py / example_matlab.m
│   └── tests/               模拟器测试（Python、MATLAB 交叉比对）
└── 05_host_app/
    ├── AWG47DR_V1/          免安装上位机（约 260 MB）
    │   ├── AWG47DR_V1.exe   双击启动
    │   ├── firmware/        上位机「一键下载 bit 并初始化」直接使用的 bit/elf/tcl/xsa
    │   └── _internal/       依赖库（不要单独移动 exe）
    └── build_exe/           重新打包 exe 的脚本
```

## 0. 拷到其他电脑前必读

- **放在纯英文、短的路径下**，例如 `D:\awg47dr\rf_awg_eth_v1_handoff_20261112`。
  - 交接包内最深的文件相对路径有 193 个字符，所以交接包文件夹本身的路径要 **≤ 66 个字符**，否则会超过 Windows 260 字符上限，复制或解压时会漏文件；
  - Vivado/XSCT 也不支持中文路径。
- 复制整个文件夹即可（建议用 robocopy 或 7-Zip），不需要安装 Python。
- 这台电脑需要装 Vivado + Vitis 2025.2（含 JTAG 线缆驱动）。
  - 上位机和所有脚本都会自动寻找安装位置：环境变量 `AWG_XILINX_ROOT`、`XILINX_VIVADO`、PATH，以及各磁盘的 `AMDDesignTools\<版本>`、`Xilinx\<版本>`；
  - 找不到时设环境变量 `AWG_XILINX_ROOT=<安装根目录>`，例如 `C:\Xilinx\2025.2`。
- 40G 网卡 IP 用 **192.168.42.20**（不要用 .10，见第 3 节），MTU 9000。
- 已在本机模拟「全新电脑」实测通过，条件如下：
  - 交接包拷到另一个磁盘（`E:\awg_relocate_test\...`），使用全新的 `%APPDATA%`，PATH 中没有 Python 和 Xilinx；
  - exe 自检 PASS；
  - Vivado 打开工程，588 个文件全部找到；
  - 仿真脚本 57/0；
  - **从这份拷贝一键下载 bit 并初始化：28 s 完成，自动连接，CH0 回环正确**。

## 1. 上位机（不需要安装 Python）

双击 `05_host_app\AWG47DR_V1\AWG47DR_V1.exe`。

| 用法 | 命令 |
|---|---|
| 正常连接板卡 | `AWG47DR_V1.exe`（默认 192.168.42.2:9100，可在顶栏修改） |
| 离线演示（内置 FPGA 模拟器，回环） | `AWG47DR_V1.exe --emulator` |
| 自检（不接硬件） | `AWG47DR_V1.exe --selftest`，结果写到 `%TEMP%\awg47dr_selftest.txt`，最后一行应为 `SELFTEST PASS` |

- **拷贝时要复制整个 `AWG47DR_V1` 文件夹**，`firmware\` 和 `_internal\` 必须与 exe 放在一起。
- 设置保存在 `%APPDATA%\awg_gui_v1\settings.ini`，与 V2 开发版互不影响。
- 功能：
  - 标准波形 / 导入波形（npy、csv、mat、hex）、8 通道下载（每通道都做 CRC 校验）、输出 Run/Stop；
  - 单次 / 连续采集；
  - 时域图、频谱（窗函数、M1/M2 标记），测量频率、Vpp、RMS、SFDR、SINAD/SNR；
  - 存档（CSV + JSON）。

## 2. 一键下载 bit 并初始化

菜单 **设备 → 下载 bit 并初始化…**（Ctrl+F5），流程：
1. 确认对话框；
2. 用 XSCT 执行 `firmware\program.tcl`：PS 复位、psu_init、运行初始化固件、等 LMK 时钟稳定、下载 bit、RFDC/MTS 初始化；
3. 自动等待光口通且 `ps_ready=1`，然后连接。全程约 1 分钟。

日志窗口（菜单 视图 → 日志）会逐行显示 xsct 输出。

**这台电脑需要：**
- 安装 **Vivado 或 Vitis（含 xsct 和 JTAG 线缆驱动）**，建议 2025.2。
  - 上位机会自动查找：已保存的路径、环境变量 `XILINX_VITIS`、PATH，以及各磁盘的 `AMDDesignTools\*\Vitis\bin\xsct.bat`、`Xilinx\...` 等常见安装位置；
  - 找不到时，用 **设备 → 设置 XSCT 路径** 指定 `xsct.bat`。
- JTAG 线连接板卡。hw_server 默认由 xsct 在本机自动启动；用远程 hw_server 时在 **设备 → 设置 hw_server 地址** 填 `host:3121`。
- 建议把交接包放在**纯英文、无空格的路径**下（XSCT/Tcl 对中文路径不保证）。
- 要换成别的 bit 或固件：**设备 → 设置固件包目录**，目录里必须有 bit、elf、psu_init.tcl、init_protocol.txt 四个文件。

不用上位机也可以手动烧写：

```
xsct 01_board_release\program.tcl -package 01_board_release
```

`-server localhost:3121` 可选，用于连接已在运行的 hw_server。

## 3. 网络设置

| 项目 | 设置 |
|---|---|
| 板卡 | IP 192.168.42.2，MAC 02:47:41:00:00:02，UDP 9100 |
| PC 40G 网卡 | 原测试 PC：192.168.42.10。**其他电脑：192.168.42.20**（或 .3–.254 中除 .10 以外的任一地址），掩码 255.255.255.0 |
| 巨型帧 | 网卡 MTU / Jumbo Packet 设 **9000**（上位机默认每包 2048 字 = 8216 B） |

- **其他电脑不要用 192.168.42.10。** FPGA 对 .10 写死了静态 ARP，指向原测试 PC 的网卡 MAC `6c:b3:11:21:7d:8e`，而且优先于 ARP 缓存（`rtl/eth/v3_qsfp2/arp.v` 第 389 行）。别的电脑用 .10 会收不到任何回复。用其他地址时会走正常 ARP，不需要改 FPGA。
- 板卡回复发往请求的来源 IP 和端口。
- 如果网卡不支持巨型帧，把上位机顶栏的「每包字数」改成 256。

## 4. 工程（02_project/rf_awg_eth_v1）

- 入口文档：
  - `doc/00_ETH_PLAN.md`：总体架构与协议；
  - `doc/01_DATAPATH_V2.md`：数据路径与寄存器；
  - `doc/02_GUI_V1.md`：上位机。
- Vivado 工程：用 Vivado 2025.2 打开 `build/D3C_IMPL/vivado/d0_clock_probe.xpr`。
  - 源文件用 `$PPRDIR` 相对路径引用，**保持 02_project 内部目录结构不变**即可在任何路径打开；
  - xpr 里的 Project Path 是旧电脑的路径，Vivado 打开时会自动更新。
  - 已验证：从交接包路径用 Vivado 2025.2 打开，588 个文件全部找到。
  - 拷贝后文件时间戳会变，Vivado 会把 impl_1 标成 Out-of-date，这是正常的。已构建好的 bit/xsa 就在 `01_board_release`，不需要重跑；要看实现结果可直接 Open Implemented Design。
- 重新构建：
  - 所有构建和仿真脚本（`scripts/`、`sim/`、`software/build/`）都通过 `scripts/xilinx_tools.ps1` 自动寻找 Vivado/Vitis，并自动设置 `PROCESSOR_ARCHITECTURE=AMD64`，不需要改路径。
  - 位元流：`powershell -ExecutionPolicy Bypass -File scripts\d3\run_build_d3.ps1`。
  - 固件：`powershell -ExecutionPolicy Bypass -File software\build\build_fw.ps1`。
    - 默认使用 `build\D3C_IMPL\awg_eth_v2.xsa`，输出到 `build\F1\package`；
    - BSP 中间文件没有放进交接包（路径太长），首次运行时会自动重新生成。
  - 上位机源码运行：`cd tools`，然后 `py -X utf8 -m awg_gui`。需要 Python 3.12 与 numpy、scipy、PySide6、pyqtgraph。测试：`py -X utf8 -m pytest -q awg_eth/tests awg_gui/tests`，应为 36 passed。
  - 重新打包 exe：`tools/packaging/build_exe.ps1`（PyInstaller 6.22.3）。
- 仿真：`sim/` 下各 `run_*.ps1`（xsim 2025.2）。

## 5. 已验证 / 未验证

- 上板（D3C + F1）：
  - 初始化成功；
  - 8 通道 × 131072 点下载 CRC 全对；
  - 起播同步与手动采集，8 通道 × 65520 点回读正确；
  - 回环 CH0 测得 99.96483 MHz（设定 99.964905 MHz）。
  - 详见 `03_results/E5C`、`E6_GUI`。
- exe 自检：
  - 在本机通过；
  - 拷到含中文和空格的路径、PATH 中没有 Python 时也通过。
- **「一键下载 bit 并初始化」已上板实测 3/3 成功**：用本包的 exe，每次 25–28 s。
  - 每次烧录后板子都确实复位（烧录前设的输出状态被清除）；
  - BUILD_ID 为 D3C；CH0 回环 99.96483 MHz；
  - 8 通道下载含 CRC 0.11 s。
  - 详见 `03_results/E7_ONECLICK`。
- 上位机日志同时写到 `%APPDATA%\awg_gui_v1\logs\awg_gui_YYYYMMDD.log`。出问题时把这个文件发给开发者。
- 命令行一键烧录：`AWG47DR_V1.exe --program`，会弹确认框；加 `--yes` 不弹。完成后自动连接。
- 初始化失败时：
  - 可改用手动 `program.tcl`；
  - 也可以用 `read_init_trace.tcl` 读初始化日志：`xsct read_init_trace.tcl <host:3121> <log 地址> <长度地址> <stage 地址> <输出文件>`，地址见 `init_protocol.txt`。
- 已知：CH0 回环线上有 27–39 MHz 外部干扰突发（DAC 停止时也存在）。

## 7. 脚本接口（06_script_api）

不打开上位机，直接在 Python 或 MATLAB 脚本里控制板卡（类似仪器驱动函数）。

| 功能 | 函数 |
|---|---|
| AWG | `awg_generate_waveform`（标准波形）、`awg_scale_waveform`（dBFS 幅度缩放与 14 bit 量化）、`awg_download`（下载 + CRC + 自动 Run）、`awg_output`（Run/Stop）、`awg_status` |
| DSO | `dso_capture`（手动或起播同步采集）、`dso_spectrum`（dBFS 频谱）、`dso_measure`（频率、幅度、SFDR、SINAD、SNR、ENOB） |

- 每个函数都只有一个函数体：不调用其他函数，没有子函数，可单独复制使用。
- Python 和 MATLAB 一一对应，结果一致。MATLAB 用自带的 Java 通信，不需要工具箱。
- 注释和说明文档都是简体中文：`06_script_api\README_脚本接口说明.md`。
- 已在模拟器测试（注入丢包和重复包），并在板上实测：
  - Python：8 通道下载含 CRC 0.12 s，采集 2 通道 × 65520 点 39 ms；
  - MATLAB：1 通道下载 0.10 s，采集 65520 点 147 ms。

## 6. 版本关系

- V1：tag `awg-eth-v1`；V1.1 加了一键烧写菜单；V1.2 是本包，改为便携版（exe 自带固件、自动找 xsct、自检）。
- V2 正在开发，在分支 `eth40g`：
  - UDP 9101 直写直读，目标 10–20 Gb/s；
  - ADC 加长到每通道 245,760 点，单通道最长 1,966,080 点；
  - V2 的 bit 保留 V1 的 9100 协议，但新功能（直写直读、加长采集）只有 V2 上位机能用。请把本包的 V1 bit 与 V1 上位机配套使用。
