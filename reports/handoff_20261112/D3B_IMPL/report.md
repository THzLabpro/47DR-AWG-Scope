# D3B_IMPL — 相位扇出修正 + 全晶片實現、bitstream、XSA

結論：**PASS**。第一段（RTL 修正與模擬）和第二段（實現、bitstream、XSA）都已通過。執行者是 Claude；原本派 Codex，因孤兒行程失控而停用（見 commit 2e44484）。全程沒有任何硬體操作。

## 第一段：RTL 與模擬

| 項目 | 結果 |
|---|---|
| TX 單元 TB（含兩種 dac reset 相位） | 70 PASS / 0 FAIL |
| RX 單元 TB（含 R6：兩種 rx 相位釋放 reset） | 29 / 0；兩種相位延遲都是 12 樣點，偏移都是 2.4 ns |
| control TB | 48 / 0 |
| bridge TB | 115 / 0（S10 59.3 MB/s） |
| 系統 TB | 245 / 0；S5 兩通道各比 1536 點 0 mismatch；回環距離違規 0 |

## 綜合

- synth_1：0 error、0 critical warning。
- 相位複本稽核（`phase_replica_audit.txt`）：

| 暫存器 | cell 數 | 預期 | 最大扇出 |
|---|---|---|---|
| `tx_phase_tog_r` | 8 | 8 | 9 |
| `tog_q` | 32 | 32 | 1 |
| `fh_q` | 32 | 32 | 58 |
| `rx_phase_tog_r` | 8 | 8 | 3 |
| `rtog_q` | 8 | 8 | 1 |
| `ph_q` | 8 | 8 | 337（同域；原 `adc_phase` 是 2690） |

## 實現

- 第 1 次嘗試就收斂。策略是 Vivado Implementation Defaults，加 phys_opt AggressiveExplore 與 post-route phys_opt。第 2、3 次策略沒有使用。
- 整體：WNS +0.005、TNS 0、WHS +0.005、THS 0、WPWS +0.033，所有使用者時序約束都滿足。
- route：98476 個可繞線網路全部完成，0 個 routing error。
- DRC：0 error。Warning 都是 DSP 管線、LUT 方程式、RAMB 寫入碰撞提示、1 個無負載網路。
- dbg_hub：`C_CLK_INPUT_FREQ_HZ=100000000`、`C_ENABLE_CLK_DIVIDER=false`、`C_USER_SCAN_CHAIN=1`、clk = `fclk_100m`，都已生效。
- clock interaction：沒有 Unsafe。只有 4 個同域 "Partial False Path"，來自 IP 的 reset 同步器，屬於 Clean。
- CDC：沒有 Critical。CDC-2/5/6/15/26 Warning 與 D3A6 同類，主要是廠商 IP 和 LUTRAM 碰撞提示。
- methodology：TIMING-54 ×1（光口 IP 的 scoped clock group）。D3B0 已分類接受，與 v3 上板版本相同。

### 各時鐘域（與 D0R2 時序探測對照）

| 時鐘 | 週期 | WNS | WHS | D0R2 WNS |
|---|---|---|---|---|
| dac `clk_out1_system_clk_wiz_0_0` | 1.633 | +0.057 | +0.040 | +0.263 |
| `tx_clk` | 3.266 | +0.123 | +0.015 | +0.512 |
| adc `clk_out1_system_clk_wiz_adc_0` | 2.400 | +0.257 | +0.026 | +0.580 |
| `rx_clk` | 4.800 | +0.464 | +0.018 | +1.811 |
| `clk_pl_0` | 10.0 | +2.500 | +0.012 | +2.531 |
| `txoutclk_out[0]` | 3.2 | +0.089 | +0.011 | — |
| `rxoutclk_out[0]` | 3.2 | +0.723 | +0.013 | — |
| `clk_out1_demo_management_clock` | — | +8.447 | +0.042 | — |
| dbg_hub TCK | — | +11.336 | +0.026 | — |

### 跨域

| From → To | WNS | WHS | D0R2 |
|---|---|---|---|
| tx_clk → dac | +0.175 | +0.038 | +0.256 |
| dac → tx_clk | +0.129 | +0.071 | — |
| adc → rx_clk | **+0.005** | **+0.005** | +0.673 |
| rx_clk → adc | +0.956 | +0.105 | — |
| clk_pl_0 ↔ tx_clk | +1.746 / +2.759 | — | — |
| tx_clk → rx_clk | +8.285 | — | — |
| txoutclk ↔ rxoutclk | +2.370 / +2.174 | — | — |

D0R2 是只有時鐘與邊界層的探測設計，邏輯少很多，所以各域餘量比 D3B 大，這是預期中的。

### 最緊路徑：adc → rx_clk（+5 ps）

- 起點是 `rx_i/adc_pair_valid_q_reg`，只有一顆暫存器。它跨到 rx_clk，當作 `channel_bram[*].channel_write_data_q` 的 CE 使用。
- 需求 2.4 ns（同源 ÷2，一個 adc 週期），資料延遲 2.100 ns（LUT 0.115 + 佈線 1.985），skew −0.144。
- 時序有收斂，但這是單一暫存器的高扇出跨域，和 S1 是同一類問題，任何重建都可能讓它掉到負值。
- **建議（後續，非本任務）**：把 `adc_pair_valid_q` 改成每通道一份、加 DONT_TOUCH（和 `ph_q[ch]` 同一套做法），讓 rx 寫入的 CE 在本地產生。

## 資源（routed，對照 D3A6 綜合）

| 資源 | D3B routed | D3A6 synth | 說明 |
|---|---|---|---|
| CLB LUT | 33501 | 36926 | opt_design 清掉冗餘，含 dbg_hub |
| CLB 暫存器 | 60202 | 63238 | 同上；相位複本只多 +72 顆 |
| Block RAM Tile | 269（RAMB36 261 + RAMB18 16） | 269 | 不變 |
| URAM | 56（70%） | 56 | 不變 |
| DSP | 1 | 1 | |
| GTYE4_CHANNEL | 4 / 8 | 4 | fsve1156 只引出 8 個 |
| BUFGCE / BUFGCE_DIV / MMCM | 7 / 2 / 3 | | |

## 產物

| 檔案 | 大小 | sha256 |
|---|---|---|
| `build/D3B_IMPL/awg_eth_v2.bit` | 21343599 | `F9DC662409A7071430A78BFAB17AD2FE8AB195829203DCC13EA5ECFA459BE638` |
| `build/D3B_IMPL/awg_eth_v2.xsa` | 3735811 | `50B3AFC35474332E7352BFC2163164B6B88F78693D791240EB54300A222E52D4` |

XSA 內含 `awg_eth_v2.bit`（大小與單獨的 bit 相同）、`.mmi`、`system.hwh`、psu_init。

## 建置腳本事件

- `build_d3.tcl` 在最後一步算 sha256 時失敗：Vivado 環境裡的 `powershell`（Windows PowerShell 5）找不到 `Get-FileHash`。因此 log 沒有 `D3B_IMPL_PASS` 標記，exit code 1。
- 失敗發生在 bit 複製和 XSA 產生之後，前面的步驟（實現、報告、DRC、dbg_hub 核對、bit、XSA）都已完成。sha256 由 Claude 用 pwsh 7 補算，寫進 `artifacts.txt`。
- 已修正：Tcl 端只寫大小，sha256 改由 `run_build_d3.ps1` 在確認 PASS 標記後用 pwsh 計算。這次沒有為此重跑 2 小時的建置。

## 下一步

1. F1 韌體（Claude）：`software/src/main.c`
   - `DAC_EXPECTED_RATE_GSPS` 改 9.8；
   - `DAC_FABRIC_CLOCK_HZ` 改 612500000；
   - 開機訊息的 DAC 速率和 JTAG 字樣；
   - 從新 XSA 走 SDT 重建 BSP 與 ELF。
2. E3 主機工具補 COMMAND=32 abort；doc/00 §6 改成 8 GTY。
3. （建議）`adc_pair_valid_q` 每通道複製，提高 adc→rx 餘量。
4. E5 上板測試：需使用者明確同意。
