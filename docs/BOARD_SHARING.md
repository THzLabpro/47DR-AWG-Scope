# 两套上位机共用 FPGA

共板 V2 使用各自上位机里的状态条，无需网页。实验室 v07 服务已常驻运行，自动交接已启用；原生窗口正常关闭、测试运行中关闭、断线超时三种实板交接均通过，47DR 回采与 RF-UDP 数据回环已验证。验收范围与限制见 [本轮验收](BOARD_SHARING_VALIDATION_20261117.md)。

## 使用方式

共享模式保留原有波形、采集和 RF-UDP 页面。首次连接填写实验室服务地址和姓名，以后自动记住；上方显示谁在使用、使用的工程、排队人员及板卡上次确认的身份。没有预计用时，也不会因为用得久而强制释放。

点击原来的下载或测试按钮时，空闲板卡会进入本次实验；有人使用时会显示对方姓名，确认加入队列后自动执行本次提交的操作，不必轮到后再点开始。提交时固定参数、数据和已登记固件版本；要修改任务，先取消再提交。允许切换版本的确认包含在提交步骤中。

单次下载或采集结束后仍保留整场实验占用。点击“结束使用”或关闭窗口，服务先停止测试与输出、关闭连接，再交给下一位。清理不能确认时显示“待恢复”，不自动放行；不要把关闭串口当成 FPGA 已停止输出。

客户端失联有 30 秒重连宽限。超时后，等待任务取消，持有人由服务清理。恢复入口会明确提示重新初始化，不会默默重启板卡。网页 V1 原型及其领用文件接口仅作为历史兼容代码保留，不用于 V2。

## 客户端入口

47DR 源码入口：

```powershell
host\Start_AWG_Scope.cmd
```

RF-UDP 源码入口，在 RF-UDP 工程根目录运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File host\start_analyzer.ps1 -Shared
```

两者无参数启动默认进入共享模式。指定地址时，47DR 使用 `--shared --share-url`，RF-UDP 使用 `-Shared -ShareUrl`。可直接使用 `host/dist/shared_clients_20261117_v07/` 中的 `47DR_Shared.exe` 和 `RFUDP_Shared.exe`；应复制各自完整文件夹，不单独复制 exe。客户端不需要固件包或 Vivado。

## 实验室端配置

本版不上传固件。完整匹配的 bit、ELF、初始化脚本先放到实验室，管理员使用 `board_share.configure_lab` 登记，并将源码目录、XSDB/XSCT、服务监听地址和 FPGA 网卡地址显式传入。生成器只读文件并计算 SHA-256，不访问硬件；输出文件须不存在，避免覆盖已有配置。

```powershell
py -3 -m board_share.configure_lab --help
py -3 -m board_share.lab_service --config 已登记配置.json --check
```

正式服务入口为 `board_share.lab_service --config 已登记配置.json`，使用独立的 `board_share_v2.sqlite3`，默认端口 4749。服务重启后进入待恢复状态，需要明确初始化确认，旧队列不会重放。配置生成器中的 `cleanup_validated` 默认是 `false`；本实验室 v5 配置已完成数字停止读回、连接释放及交接验收，设为 `true`。该检查不代表仪器测得 RF 端口零功率。

新服务直接调用两个硬件适配器，两个共享客户端都连接新服务。不要把 V1 的 `board_share serve` 或 `--board-share-url` 当成 V2 调度器。旧 4748 服务及其开机任务已停止和禁用；日常统一使用 4749。此机制不阻止绕过入口的 Vivado、JTAG 或直接 UDP 操作。

实验室使用独立的 `FPGA_Shared_Service.exe`，无需安装 Python。当前目录为 `G:\pkg\02_project\host\shared_service_20261117_v07\`，配置为 `lab_config_v5.json`，由 SYSTEM 计划任务 `FPGA_BoardShare_v2` 开机启动。通常不必手动启动同目录的 `Start_Shared_Service.cmd`，单实例锁会拒绝重复启动。`--config 配置.json --check` 只核对文件，`--offline-check` 只加载驱动模块。

## 源码和维护

- `host/tools/board_share/`：47DR 工程中的公共调度器、Qt 状态条、客户端和实验室适配器。
- `host/tools/awg_gui/shared_window.py`：47DR 共享模式，原直连窗口保留。
- RF-UDP 的 `host/analyzer/remote_window.py`：RF-UDP 远程窗口，使用同一份公共模块的 `board_share/` 副本。
- `host/packaging/build_shared_clients.ps1`：生成两个独立客户端；RF-UDP 打包需传入其源码根目录。
- `host/packaging/build_lab_service.ps1`：生成独立实验室服务，不包含固件，不自动部署。

公共模块修改后须同步两处并核对哈希。离线实现与后续实验室部署、硬件访问的具体范围分别记录在验收文档中。
