# 两套上位机共用 FPGA

共板 V2 使用各自上位机里的状态条，无需网页。实验室 v07 服务已常驻运行，自动交接已启用；原生窗口正常关闭、测试运行中关闭、断线超时三种实板交接均通过，47DR 回采与 RF-UDP 数据回环已验证。验收范围与限制见 [本轮验收](BOARD_SHARING_VALIDATION_20261117.md)。

## 使用方式

共享模式保留原有波形、采集和 RF-UDP 页面。首次连接填写实验室服务地址和姓名，以后自动记住；上方显示谁在使用、使用的工程、排队人员及板卡上次确认的身份。没有预计用时，也不会因为用得久而强制释放。

点击原来的下载或测试按钮时，空闲板卡会进入本次实验；有人使用时会显示对方姓名，确认加入队列后自动执行本次提交的操作，不必轮到后再点开始。提交时固定参数、数据和已登记固件版本；要修改任务，先取消再提交。允许切换版本的确认包含在提交步骤中。

单次下载或采集结束后仍保留整场实验占用。点击“结束使用”或关闭窗口，服务先停止测试与输出、关闭连接，再交给下一位。清理不能确认时显示“待恢复”，不自动放行；不要把关闭串口当成 FPGA 已停止输出。

客户端失联有 30 秒重连宽限。超时后，等待任务取消，持有人由服务清理。恢复入口会明确提示重新初始化，不会默默重启板卡。网页 V1 原型及其领用文件接口仅作为历史兼容代码保留，不用于 V2。

## 客户端入口

只使用客户端时，从 [v2.1.1 发行页](https://github.com/THzLabpro/47DR-AWG-Scope/releases/tag/shared-clients-v2.1.1) 下载对应 Windows ZIP，完整解压后运行 `47DR_Shared/47DR_Shared.exe` 或 `RFUDP_Shared/RFUDP_Shared.exe`。`git clone` 不下载这些附件；本仓库也不包含 RF-UDP 完整工程。不要把发行页自动生成的 `Source code` 包当作可运行客户端。

47DR 源码入口：

```powershell
host\Start_AWG_Scope.cmd
```

RF-UDP 源码入口，在 RF-UDP 工程根目录运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File host\start_analyzer.ps1 -Shared
```

指定地址时，47DR 使用 `--shared --share-url`，RF-UDP 使用 `-Shared -ShareUrl`。实验室已打包客户端位于 `G:\pkg\02_project\host\shared_clients_20261117_v07\`，也可从这里复制各自完整文件夹，不单独复制 exe。源码仓库中的 `host/dist/` 是本机打包输出，不随 Git 拉取。客户端不需要固件包或 Vivado。

## 第一次连接和常见提示

1. 在自己的电脑接入可访问实验室电脑的 Tailscale 网络；实验室电脑须开机，公共服务须运行。
2. 打开客户端，确认服务地址 `http://100.121.70.53:4749`，填写自己的姓名。姓名用于显示使用人，复制别人客户端时也应检查并改成自己的姓名。
3. 连接后先看状态条。查看状态不会占板；提交下载或测试后才申请使用。有人使用时，可以按显示的姓名联系交接，也可以确认排队。
4. 轮到后自动执行提交时的任务；跨工程切换要等待固件初始化。完成实验后点“结束使用”或正常关窗。

连接失败时，先检查 Tailscale、实验室电脑是否开机、地址和端口是否正确；不要改回旧端口 4748。仍失败时把完整报错交给维护者检查服务。显示“待恢复”时，交由维护者核对故障并按明确的恢复提示处理，不以反复重启板卡作为常规操作。

## 完整工程在哪里

| 内容 | 位置与阅读入口 |
|---|---|
| 47DR 客户端、公共调度源码 | 本 GitHub 仓库，先读根 `README.md` |
| RF-UDP 独立工程 | 实验室 `G:\pkg\02_project`，开发阅读入口为 `START_HERE.md` 与 `V4_README.md` |
| 47DR V2.1 FPGA 历史交接包 | [旧版 awg-eth-v2.1 发行页](https://github.com/THzLabpro/47DR-AWG-Scope/releases/tag/awg-eth-v2.1)，保留完整交接包；不要把本仓库的历史 `fpga/` 当成当前 D4B/F3 工程 |

只运行客户端无需复制上述 FPGA 工程。修改 RTL、重编译固件属于开发工作；拷贝工程后仍需核对工具版本和路径依赖，不能把客户端运行通过视为工程重建通过。

## 实验室端配置

本版不上传固件。完整匹配的 bit、ELF、初始化脚本先放到实验室，管理员使用 `board_share.configure_lab` 登记，并将源码目录、XSDB/XSCT、服务监听地址和 FPGA 网卡地址显式传入。生成器只读文件并计算 SHA-256，不访问硬件；输出文件须不存在，避免覆盖已有配置。

```powershell
py -3 -m board_share.configure_lab --help
py -3 -m board_share.lab_service --config 已登记配置.json --check
```

正式服务入口为 `board_share.lab_service --config 已登记配置.json`，使用独立的 `board_share_v2.sqlite3`，默认端口 4749。服务重启后进入待恢复状态，需要明确初始化确认，旧队列不会重放。配置生成器中的 `cleanup_validated` 默认是 `false`；本实验室 v5 配置已完成数字停止读回、连接释放及交接验收，设为 `true`。该检查不代表仪器测得 RF 端口零功率。

新服务直接调用两个硬件适配器，两个共享客户端都连接新服务。不要把 V1 的 `board_share serve` 或 `--board-share-url` 当成 V2 调度器。旧 4748 服务及其开机任务已停止和禁用；日常统一使用 4749。此机制不阻止绕过入口的 Vivado、JTAG 或直接 UDP 操作。

实验室使用独立的 `FPGA_Shared_Service.exe`，无需安装 Python。当前目录为 `G:\pkg\02_project\host\shared_service_20261117_v08\`，配置为 `lab_config_v6.json`，由 SYSTEM 计划任务 `FPGA_BoardShare_v2` 开机启动。通常不必手动启动同目录的 `Start_Shared_Service.cmd`，单实例锁会拒绝重复启动。`--config 配置.json --check` 只核对文件，`--offline-check` 只加载驱动模块。

## 源码和维护

- `host/tools/board_share/`：47DR 工程中的公共调度器、Qt 状态条、客户端和实验室适配器。
- `host/tools/awg_gui/shared_window.py`：47DR 共享模式，原直连窗口保留。
- RF-UDP 的 `host/analyzer/remote_window.py`：RF-UDP 远程窗口，使用同一份公共模块的 `board_share/` 副本。
- `host/packaging/build_shared_clients.ps1`：生成两个独立客户端；RF-UDP 打包需传入其源码根目录。
- `host/packaging/build_lab_service.ps1`：生成独立实验室服务，不包含固件，不自动部署。

公共模块修改后须同步两处并核对哈希。离线实现与后续实验室部署、硬件访问的具体范围分别记录在验收文档中。


## F3 切换后的光口恢复

47DR 初始化完成后，服务先检查 UDP 9100/9101。仅在连接超时且配置已登记恢复脚本时，才通过 JTAG 只读核对 F3 BUILD、ABI、采样率、PS 就绪、无故障及未播放状态，再重启板卡路由实际选中的光口网卡一次，并重新验证连接。正常连接不会重启网卡；错误工程、PS 未就绪、其他 JTAG 会话、取消或恢复失败均不会反复重启。

实验室 v6 配置按网卡 GUID 登记两个光口，实际选择还必须匹配到板卡的路由和主机源 IP。不会修改 IP、MTU 或其他网卡。客户端继续使用原有共享入口和日志，无需更新界面。此功能目前只用于 47DR/F3，不自动处理 RF-UDP 故障。

生成新配置时，增加 `--vivado` 和可重复的 `--optical-adapter-guid` 参数；省略两者则保留原行为。新增 Tcl、PowerShell 脚本纳入固件包哈希检查，服务打包脚本同时包含这两个依赖。验收范围见 [共享服务验收记录](BOARD_SHARING_VALIDATION_20261117.md)。
