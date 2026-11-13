# D1R2_TX 執行報告

狀態：`NEEDS_PARENT_JUDGMENT`

## 完成檔案

- `rtl/tx/awg_tx.sv`：FIFO 改為 64 深 LUTRAM，tx 讀端加資料暫存；改成單一 448-bit 移位打包器；寫入點數與回捲計數以 Gray 碼同步，CRC 結果使用完成 toggle 與穩定資料 mailbox；補上 URAM 讀延遲對齊、DAC 相位複本和資料路徑無 reset 寄存器。
- `rtl/tx/awg_tx_uram_block.sv`：使用 UltraRAM XPM simple-dual-port RAM，`READ_LATENCY_B=3`。
- `sim/tx/run.ps1`、`sim/tx/run_ooc.ps1`：模擬輸出固定至 `build/D1R2_TX/`，結果與 Vivado log 寫至 `reports/D1R2_TX/`。
- `sim/tx/ooc_d1r2_tx.xdc`：定義 dac/tx/host 時鐘及 CDC 約束；CDC helper 使用 `proc`，Vivado 2025.2 的 XDC parser 不支援，詳見未通過項目。
- `build/D1R2_TX/ooc.tcl`、`build/D1R2_TX/awg_tx_ooc_top.sv`：OOC 流程及以 BUFGCE_DIV ÷2 連接 dac_clk/tx_clk 的實作 wrapper。
- `reports/D1R2_TX/`：xsim、Python CRC、Vivado OOC、timing、CDC、RAM、utilization、route、clock interaction、bus skew 及 methodology 報告。

## 執行命令與結果

1. `powershell.exe -NoProfile -ExecutionPolicy Bypass -File sim/tx/run.ps1`
   - xvlog、xelab、xsim 最終執行：PASS。
   - T1–T6：`PASS=26 FAIL=0 mismatches=0 x_count=0`。
   - T6：`accepted_words=524288`、`elapsed_ns=10488480`、`host_words_per_second=49987033.393`。
   - 日誌：`xsim.log`。
2. `py -X utf8 sim/tx/crc_ref.py --channel 0 --points 131072`
   - Python CRC：`D49307A0`，與 TB RTL/SystemVerilog CRC `d49307a0` 相同。
   - 日誌：`crc_ref.log`。
3. `powershell.exe -NoProfile -ExecutionPolicy Bypass -File sim/tx/run_ooc.ps1`
   - Vivado 2025.2、`xczu47dr-fsve1156-2-i`，synth/place/route 完成；route status 為 0 routing errors、24812 routable nets 全部 routed。
   - 第二次 OOC 執行為最終判定；完整 log 為 `ooc_vivado.log`。同路徑報告由第二次執行覆寫，第一次執行數字不納入判定。

## 固定驗收

| 項目 | 結果 | 證據 |
|---|---|---|
| T1–T6、CRC | PASS | `xsim.log`：26 PASS、0 FAIL；Python/RTL CRC 都是 `D49307A0`。 |
| OOC setup/hold | FAIL | hold 全部非負，但 setup WNS 有負值；見下表。 |
| CDC Critical | FAIL | `report_cdc` 有 2 個 CDC-10 Critical。 |
| 資源 | PASS | URAM288=56、RAMB36/FIFO=0、RAMB18=0；LUT logic=3914、LUT memory=48、CLB registers=22087。 |
| URAM OREG / latency | PASS | `report_ram_utilization` 對 56 個 URAM 顯示 `OREG_B=1`、`DOB_REG=1`、Read latency 3.3 ns；XPM 參數為 READ_LATENCY_B=3。 |
| 實現輪數 | 已停止 | OOC 已執行兩輪；依 AGENTS.md 同一失敗最多兩輪，不再啟動第三輪。 |

最終 `report_timing_summary` 數字（ns）：

| 路徑群組 | WNS | WHS | 判定 |
|---|---:|---:|---|
| dac_clk 域內 | -1.263 | +0.040 | setup FAIL |
| tx_clk 域內 | -2.225 | +0.010 | setup FAIL |
| host_clk 域內 | +5.887 | +0.043 | PASS |
| tx_clk → dac_clk | -1.737 | +1.463 | setup FAIL |
| host_clk → tx_clk | -2.301 | +0.017 | setup FAIL |
| tx_clk → host_clk | -2.941 | +1.350 | setup FAIL |
| 全設計 | -2.941 | +0.010 | setup FAIL |

時鐘摘要：dac_clk 612.370 MHz、tx_clk 306.185 MHz、host_clk 100 MHz。`report_clock_interaction` 將 tx_clk→dac_clk 判為 synchronous/clean；host_clk↔tx_clk 為無共同時鐘的跨域路徑。

## CDC 警告與 Critical

`report_cdc` 摘要為 CDC-3 Info 17、CDC-6 Warning 15、CDC-10 Critical 2、CDC-15 Warning 65。

- CDC-10 Critical 2：`state_reg` 解碼後分別直接進 `crc_busy_h1`、`running_h1`。這兩條同步器前有組合邏輯，尚未處理。
- CDC-6 Warning 15：8 組寫入樣點 Gray 計數、1 組 wrap Gray 計數、2 組 FIFO Gray 指標，以及 `crc_ch`、`length`、`mask`、`rewind_ch` 四組多位元 mailbox。Gray 計數器只在 word/wrap 邊界遞增；mailbox 資料由控制 toggle 搭配保持資料使用。Vivado 將它們列為 ASYNC_REG 多位元同步警告；本次 XDC bus-skew 約束未生效，不能視為已完成時序約束。
- CDC-15 Warning 65：CRC 結果資料 mailbox 的 clock-enable 擷取，以及 LUTRAM FIFO 讀出至 tx_clk 資料暫存器的 clock-enable 結構。前者配合 CRC done toggle，後者配合 FIFO Gray 指標；同樣因 XDC 約束未生效，仍需重新審查。
- CDC-3 Info 17：單位元 toggle/同步器由 ASYNC_REG 兩級同步，列為資訊項。

## 最差 10 條路徑

以下取自 `ooc_impl_paths.rpt`，皆為 tx_clk → host_clk，且因 XDC CDC 最大延遲約束未生效而以無共同時鐘邊緣分析：

| # | Slack (ns) | 起點 → 終點 |
|---:|---:|---|
| 1 | -2.941 | `rd_fifo_gray_reg[0]/C` → `rd_fifo_gray_h1_reg[0]/D` |
| 2 | -2.895 | `crc_value_tx_reg[13]/C` → `crc_value_host_reg[13]/D` |
| 3 | -2.889 | `rd_fifo_gray_reg[1]/C` → `rd_fifo_gray_h1_reg[1]/D` |
| 4 | -2.886 | `crc_value_tx_reg[21]/C` → `crc_value_host_reg[21]/D` |
| 5 | -2.884 | `crc_value_tx_reg[1]/C` → `crc_value_host_reg[1]/D` |
| 6 | -2.880 | `crc_value_tx_reg[14]/C` → `crc_value_host_reg[14]/D` |
| 7 | -2.880 | `crc_value_tx_reg[25]/C` → `crc_value_host_reg[25]/D` |
| 8 | -2.878 | `crc_value_tx_reg[4]/C` → `crc_value_host_reg[4]/D` |
| 9 | -2.868 | `crc_value_tx_reg[12]/C` → `crc_value_host_reg[12]/D` |
| 10 | -2.865 | `crc_value_tx_reg[11]/C` → `crc_value_host_reg[11]/D` |

## 停止原因與需協調

第二輪 `ooc_d1r2_tx.xdc` 經 `read_xdc` 載入時，Vivado 2025.2 記錄 23 個 `CRITICAL WARNING [Designutils 20-1307]`：XDC 不支援 `proc`，因此 `constrain_cdc_bus` / `constrain_cdc_bit` 呼叫被略過。結果是 `ooc_impl_bus_skew.rpt` 顯示 `No bus skew constraints`，設定的 CDC `set_max_delay` 亦未套用。第二輪 OOC 的 CDC WNS/CDC 警告未能驗收；此外仍有 2 個 CDC-10 Critical 和 dac_clk/tx_clk 域內 setup 負 slack。

依固定兩輪限制停止於 `NEEDS_PARENT_JUDGMENT`。後續需由父層決定是否另開一輪：將 XDC helper 改成純 XDC 支援的直接約束，或讓 Tcl 腳本在 `read_xdc` 外套用約束；並處理 `state` 解碼跨域及 dac/tx 域內負 slack，再重新跑完整 OOC。沒有使用 false_path、clock_groups 或放寬時序判據。未做硬體下載、hw_server、JTAG 或網路發包。

## Claude 審查判定（2026-11-11）

功能（T1–T6 26/26、CRC `D49307A0`）與資源（URAM 56、BRAM 0、URAM 讀延遲 3 且 OREG 已用）接受。OOC 時序結果**不作為簽核依據**，原因：

1. **時鐘結構失真**：OOC 包裝層 `awg_tx_ooc_top.sv`（已從 build/ 複製到 `sim/tx/` 保存）中 `dac_clk` 直接由埠進入、沒有全域緩衝，`tx_clk` 卻經 `BUFGCE_DIV`，造成 tx→dac 時鐘偏斜 -2.74 ns（-1.737 ns 的主因）。
   真實設計中兩者必須同源、同類緩衝（例如同一 MMCM 的兩個輸出各接 BUFGCE，或同一來源的兩個 BUFGCE_DIV，DIVIDE=1/2），偏斜應在 0.1~0.3 ns 量級。
2. **邊界未定位**：dac_clk 域內 -1.263 ns 是 `dac_phase` 複本到 2048 個 `dac_tdata` 的走線（2.7 ns）。OOC 沒有 RFDC 位置，輸出暫存器被任意分散，不具代表性。
3. **CDC 約束沒生效**：XDC 檔不支援 `proc`，所有 `set_max_delay -datapath_only` / `set_bus_skew` 未套用；CDC 約束須改成 Tcl 腳本 `source`（或 `read_xdc -unmanaged`）。
4. **tx_clk 域內 -2.225 ns**：64 深 LUTRAM FIFO（`ram_style distributed`）非同步讀到 `fifo_data_stage` 走線 5.25 ns，屬布局問題；D3 改用 `xpm_fifo_async`（block 或帶輸出暫存器）。

處置：不再做 D1 OOC 第三輪；以上 1、3、4 併入 D3 整合任務，在全晶片（含 RFDC 實際位置）下簽核 TX 時序。
