# AWG47DR V2.1 板卡发布文件

47DR RFSoC AWG / 示波器（40GbE 光口版）V2.1 的位元流、初始化固件与烧写脚本。
上位机 `AWG47DR_V2.exe` 已自带同样的文件；这里给需要手动烧写或自行集成的用户。

| 项目 | 值 |
|---|---|
| 器件 | Zynq UltraScale+ RFSoC ZU47DR |
| 位元流 | V21_IMPL，BUILD_ID `0xD4B0_2026`，寄存器 ABI `0x00050000` |
| 固件 | F3（`rf_awg_init.elf`，Vitis SDT 裸机） |
| 工具 | Vivado / Vitis 2025.2 |
| DAC | 8 × 9.8 GS/s，14 bit（DAC tile 2：200 MHz × 49） |
| ADC | 8 × 5 GS/s，14 bit |
| 网络 | QSFP 40GbE，板卡 `192.168.42.2`，UDP 9100 控制 / 9101 bulk |

## 文件

| 文件 | 说明 |
|---|---|
| `rf_awg_scope_v1.bit` | FPGA 位元流（`program.tcl` 使用的文件名） |
| `awg_eth_v2.bit` | 同一个位元流（实现输出的原始文件名，SHA256 相同） |
| `awg_eth_v2.xsa` | 硬件导出文件，可用于重建固件 |
| `rf_awg_init.elf` | PS 初始化固件：配置 LMK04828、RFDC、MTS，完成后置 `ps_ready` |
| `psu_init.tcl` | PS 初始化 |
| `init_protocol.txt` | 固件与烧写脚本的握手地址（时钟就绪、PL 已下载、日志地址等） |
| `program.tcl` | XSCT 烧写 + 初始化脚本 |
| `read_init_trace.tcl` | 经 JTAG 读取初始化日志（串口被占用时用） |
| `signoff_reports/` | 时序、DRC、CDC、bus skew、资源、功耗、方法学报告 |
| `SHA256SUMS.txt` | 校验值 |

## 烧写

需要安装 Vivado 或 Vitis 2025.2（xsct + JTAG 驱动），并接好 JTAG 线。

```bat
xsct program.tcl -package <本目录>
xsct program.tcl -package <本目录> -server localhost:3121   :: 连接已在运行的 hw_server
```

流程：

1. 连接 JTAG，`rst -system`，执行 `psu_init`；
2. 下载并运行 `rf_awg_init.elf`，等待固件报告 LMK 时钟稳定（`awg_clock_ready`）；
3. 下载位元流，通知固件 PL 已就绪（`awg_pl_program_ack`）；
4. 固件完成 RFDC 与 MTS 初始化（约 20 s），STATUS bit2 `ps_ready` 变为 1。

完成后可以确认：

```python
import awg47dr as api           # 见脚本接口包
st = api.awg_status("192.168.42.2")
assert st["ps_ready"] and st["build_id"] == "0xD4B02026"
```

## 初始化日志

串口不可用时，可以经 JTAG 读回固件日志：

```bat
xsct read_init_trace.tcl <host:3121> <log 地址> <长度地址> <stage 地址> <输出文件>
```

地址见 `init_protocol.txt`。成功时日志的最后阶段是 `INIT_STAGE=99`，并打印 `AWG READY`。

## 签核结果（`signoff_reports/`）

| 项目 | 结果 |
|---|---|
| WNS / TNS | +0.072 ns / 0 |
| WHS / THS | +0.010 ns / 0 |
| WPWS | +0.033 ns |
| 未布线 / 布线错误 | 0 / 0 |
| DRC 错误 | 0 |
| bus skew | 44 / 44 达标 |
| 资源 | LUT 55,612（13.1%）、BRAM tile 803.5 / 1080、URAM 56 / 80 |
| report_cdc | 1 个 CDC-1 Critical，来自第三方 `axis_async_fifo` 的复位同步器（既有，可接受，见 `report.md`） |

## 校验

```powershell
Get-FileHash .\rf_awg_scope_v1.bit -Algorithm SHA256
# B7470AC9DA3CCF11E3AD0DACF6C0092BAD546223FCD71B1962BD2F1AAC5A1FDF
```

所有文件的校验值见 `SHA256SUMS.txt`。

## 兼容性

- 本位元流与 V2.1 上位机和 V2.1 脚本接口配套使用。
- 9100 寄存器协议保持兼容 V1，但 V1 上位机用不到 bulk 和池化功能。
- V1 位元流（BUILD_ID `0xD3C0_2026`）请使用 V1.2 的发布文件。
