# V2.1 远程控制服务

服务在实验室电脑运行，经本机 40GbE 控制配套 D4B/F3 板卡。使用者电脑运行同仓库的 Python V2.1 工作台，通过 Tailscale 连接 TCP 4748。无需额外密码；FFT、测量、文件保存和记录重开都在使用者电脑完成。远程服务已完成有限范围实板验证，详见 [实板验证记录](VALIDATION_REMOTE_BENCH_20261115.md)。

## 启动与连接

实验室电脑安装 Python 与 [host/requirements.txt](../host/requirements.txt) 依赖，确认匹配板卡已初始化、无人占用且获准操作后，从项目根目录运行：

```powershell
$env:PYTHONPATH=(Resolve-Path host/tools).Path
py -3 -m awg_eth.remote serve --bind 实验室电脑的Tailscale地址 --fpga-ip 192.168.42.2
```

默认 TCP 4748；默认监听地址为 `127.0.0.1`，跨机使用时填写实验室电脑的实际 Tailscale 地址。服务启动不会访问板卡，客户端连接时才只读检查版本及两个 UDP 端口。实验室电脑光口网卡需 MTU 9000，建议 `192.168.42.20/24`，板卡为 `.2`，不使用已有静态 ARP 绑定的 `.10`。Tailscale 和 Python 需要可用，TCP 4748 需要可达。

使用者双击唯一入口 `host/Start_AWG_Scope.cmd`，选择“实验室远程服务”，填写该地址与 4748。使用者电脑不用设置光口地址或 MTU，不用启动 hw_server。

命令行只提供读状态和显式停播：

```powershell
$env:PYTHONPATH=(Resolve-Path host/tools).Path
py -3 -m awg_eth.remote call --host 实验室电脑的Tailscale地址 status
py -3 -m awg_eth.remote call --host 实验室电脑的Tailscale地址 stop
```

服务不承担 bit 下载或 RFDC/MTS 初始化。首次上电所需 F3 固件包已放在 `host/hardware/eth40g_v2_1/`，不能用历史 D3C/F1 包代替。

## 控制权与播放

同一服务只允许一个 TCP 会话持有板卡，其他会话收到 busy。工作台连接时检查版本和当前状态，随后释放；连接状态表示远程通路已经核对，不表示一直占板。界面显示最近一次读取的播放状态，可点刷新重新读取。

| 操作 | 控制权释放时刻 |
|---|---|
| 连接、刷新状态 | 读取完成 |
| 仅下载 | 下载完成后由界面释放 |
| 下载并自动播放 | 下载到启动期间持有，启动完成释放 |
| 启动、停止、清故障 | 操作完成 |
| 单次采集 | 原始数据读回后、FFT 前 |
| 连续采集 | 持续持有，当前一帧完成并处理停止请求后释放 |
| 打开本地记录、保存、显示、分析 | 不访问板卡 |
| 断开或关闭工作台 | 完成当前请求并关闭 UDP/TCP 连接后释放 |

释放控制权不停止 DAC。下一位要换波形时必须手动停止；服务与工作台均拒绝在播放中下载。错误路径释放工作台会话；TCP 异常在服务发现后释放，空闲超时为 120 秒。通信失败时操作可能已经部分或全部执行，不能据报错推断板卡已停止；应重新读取状态再继续。不会自动重发整个修改任务。

服务锁只约束该服务的客户端，不能阻止其他程序直接发 UDP 或通过 JTAG 操作。因此实验室应统一使用一份服务；初始化仍需协调独占。当前不支持多用户同时分别操作不同通道。

## 协议与 Python 接口

握手协议名为 `47dr-remote-v21-1`，客户端和服务必须一起更新。传输帧为 4 字节网络字节序长度加 UTF-8 JSON，单帧上限 16 MiB。无密码字段。握手请求为 `{"action":"connect","protocol":"47dr-remote-v21-1"}`；成功回复含 `ok=1`、协议名与 `info`，失败为 `ok=0`、`message`。

每帧一个请求与回复。动作包括 `status`、`load_words`、`start`、`stop`、`clear`、`capture_raw`、`abort_capture`、`disconnect`。`load_words` 参数为 `channels`、`samples`、`mask`、`verify`；`capture_raw` 参数为 `trigger`（manual/start）、`mask`、`samples`、可选 `slots`。捕获回复含 `channels`、`count`、`cap_tx_word`、`read_s`、`status`。

`channels` 是物理通道数字字符串到 base64 的映射，每个样本对打包成小端 uint32，较早的 int16 样点在低 16 bit。原始数组直接传输，不经 CSV/HEX 文本转换。满容量单通道 RX 原始数据约 3.93 MB，base64 后仍小于帧上限。

Python 调用示例（实际板卡访问仍须获准）：

```python
from awg_eth.remote import RemoteAwg

awg = RemoteAwg("实验室电脑的Tailscale地址", 4748)
try:
    print(awg.status())  # 临时读取后自动释放
    # awg.load_words({0: packed_uint32_array}, samples, 1, verify=True)
    # awg.start()
    # count, cap_word, raw = awg.capture_raw("manual", 1, samples=1966080)
finally:
    awg.close()  # 不停止 DAC
```

`RemoteAwg` 的修改及采集调用会持有会话，脚本应在一个任务完成后调用 `release()` 或 `close()`。GUI 已处理上述释放规则。底层 `RemoteClient` 可用上下文管理器持有单个会话；`request(action, **params)` 接受原始协议参数。

离线验证范围见 [V2.1 本机验收](VALIDATION_20261115.md)。Tailscale 端到端吞吐、跨机断线恢复和长期运行仍待测量。
