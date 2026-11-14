# 47DR 远程控制服务（离线验证版）

服务在实验室电脑运行，接收远程任务后使用本机光口控制 D3C/F1 板卡；远程客户端通过 Tailscale 访问服务。MATLAB 界面、Python API 和命令行均已接入，尚未在实验室电脑或板卡上验证。

同一服务只允许一个客户端会话；断线后释放会话，已开始的板卡操作可能已执行，重试前检查状态。断开不会停止播放。服务锁不能阻止其他独立程序直接访问板卡或使用 JTAG，使用前仍须协调独占。断线和操作超时不代表板卡停止。

服务不需要额外密码，通过 Tailscale 地址连接。默认只监听本机回环地址，不会启动时连接板卡；客户端连接后才检查板卡身份。确认获准及无人使用后，在实验室电脑项目根目录运行：

```powershell
$env:PYTHONPATH=(Resolve-Path host/tools).Path
py -3 -m awg_eth.remote serve --bind 实验室电脑的Tailscale地址 --fpga-ip 192.168.42.2
```

需要 Tailscale 在线、实验室光口网络可达板卡，并允许服务 TCP 4748 通过本机防火墙。板卡初始化仍使用现有 JTAG 流程；服务不启动 hw_server 或初始化板卡。

客户端在自己的项目根目录运行，例如：

```powershell
$env:PYTHONPATH=(Resolve-Path host/tools).Path
py -3 -m awg_eth.remote call --host 实验室电脑的Tailscale地址 status
py -3 -m awg_eth.remote call --host 实验室电脑的Tailscale地址 run --waveform 波形目录 --capture 回采.csv --samples 65520 --mask 255 --trigger start
```

波形目录使用现有 `waveform.meta` 和 `ch0.hex` 至 `ch7.hex` 格式；回采会在客户端生成 CSV 与同名 JSON，已有文件不会覆盖。命令行还支持 `load`、`start`、`stop`、`clear`、`capture`；`run` 在同一独占会话中完成下载、启动与回采。Python 调用方可使用 `awg_eth.remote.RemoteClient` 保持会话。服务没有自动重试修改板卡的操作；通信故障后操作结果可能不确定。

MATLAB 的“连接设置”选择“实验室远程服务”，填写实验室电脑的 Tailscale 地址和 TCP 端口 4748，再点击连接。连接时获取控制权并读取播放状态；如果正在播放，要更换波形时先手动停止。下载后可继续启动；启动、采集或一键下载并采集完成后自动释放控制权，不停止 DAC。再次操作须重新连接并检查状态。仅下载、查看状态或停止之后如暂不继续，应点击“断开连接”释放控制权。回采 CSV、JSON 和 MAT 保存在客户端本机。无进度数据时远程传输显示活动状态，不提供百分比。

2026-11-13：本机回环模拟器测试覆盖无密码连接、会话独占、下载、回采和错误固件拒绝；属于软件模拟，不是实板速度或可靠性测试。服务部署、Tailscale 访问、光口链路和端到端耗时均待验证。

MATLAB 远程回环测试覆盖一键下载、客户端本地保存回采、任务结束释放控制权、重新连接后播放状态保持及更换波形前手动停止。原 MATLAB 直连回环回归通过；Python 测试 26 项通过。
