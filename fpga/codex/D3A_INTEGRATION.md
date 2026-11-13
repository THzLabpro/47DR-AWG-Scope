# D3A_INTEGRATION — v2 控制器 + 正式頂層 + 系統模擬 + 建置腳本（不跑全晶片實現）

先讀 `AGENTS.md`、`doc/00_ETH_PLAN.md`（§2–§4 凍結）、`doc/01_DATAPATH_V2.md`（全部凍結，含 2026-11-11 新增的 `tx_play_word` 握手規定）。
再讀已簽核的參考：`reports/D0R2_TIMING/report.md`（全晶片時序已收斂的時鐘/reset/CDC 寫法）、`reports/E1R2_BRIDGE/report.md`、`reports/D1R2_TX/report.md`（最後的「Claude 審查判定」節）、`reports/D2/report.md`。

本任務**只做 RTL、模擬、約束與腳本，到「綜合可以開始」為止**；全晶片綜合/實現是下一個任務 D3B，執行前 Claude 會先做唯讀審查。

## 歸屬檔案

- 新增：`rtl/top/**`、`rtl/ctrl/**`、`constraints/top/**`、`scripts/d3/**`、`sim/d3/**`、`build/D3A_INTEGRATION/**`、`reports/D3A_INTEGRATION/**`
- 允許的最小修改（每處在報告列出 diff 摘要與理由，並重跑該模組原有 TB）：
  - `rtl/tx/awg_tx.sv`：CDC FIFO 改 `xpm_fifo_async`（見下 3.2）。重跑 `sim/tx`（T1–T6，CRC 仍 `D49307A0`）。
  - `rtl/rx/awg_rx.sv` + `sim/rx/**`：加 `tx_clk` 輸入與 `xpm_cdc_handshake`（照 `doc/01`）。重跑 R1–R4。
  - `scripts/bd/create_system_v2.tcl`：只限整合必需的連線變更；改後重跑 BD 參數 diff，`unexpected=0`。
- 唯讀：`rtl/eth/**`（E1R2/E2 產物，只透過參數設定）、v1 的 `rtl/user_control.v`、`rtl/up_axi.v`、`rtl/reset_sync.v`（可直接例化）。
- xsim 只在 `build/D3A_INTEGRATION/` 下跑。

## 要做的

### 1. `rtl/ctrl/awg_control_v2.sv`

照 `doc/01` §5 暫存器表逐位實作（AXI4-Lite slave，host_clk）。重點：

- 未定義位址、非法命令、狀態不允許的寫 → SLVERR；讀未定義位址 → SLVERR。
- `TX_WR_DATA`：awg_tx 背壓時延遲 B 回應，不得丟字；**AW 與 W 同拍到達時當拍接受，下一拍可回 B**（吞吐目標見驗收）。
- `CAP_RD_DATA`：每讀一次指標 +1；awg_rx 固定延遲 ≤ 4 拍，R 回應等資料到。
- `COMMAND`=16 CRC 用 `TX_WR_CH` 的通道與 `TX_LENGTH`；start 檢查照 §5。
- `ps_ready` 來源：v1 `user_control` 的 `config_done`（PS 韌體經 up_ 匯流排寫入），同步到 host_clk。

### 2. `rtl/top/awg_eth_top.v`（正式頂層）

- 以 `rtl/d0/d0_probe_top.v`（D0R2 版本）的時鐘、reset、SYSREF、BD 例化結構為基礎，把 TX/RX stub 換成 `awg_tx`、`awg_rx`。
  - 時鐘：dac_clk = BD `data_clk`（612.5）、tx_clk = BUFGCE_DIV ÷2；adc_clk = BD `adc_capture_clk`（416.667）、rx_clk = BUFGCE_DIV ÷2；host_clk = `fclk_100m`。照 D0R2 的做法，不要另造時鐘結構。
  - 每個域自己的 reset 同步器；資料路徑不接 reset（D0R2 規則全部沿用）。
- 控制路徑：`jtag_awg_axi`（建法照 `scripts/build.tcl` 第 58–59 行）與 `awg_eth_bridge` → `axil_arb2` → `awg_control_v2`。
- 光口：`awg_eth_core`，參數 `RX_FIFO_DEPTH=32768`、`TX_FIFO_DEPTH=16384`、`UDP_CHECKSUM_PAYLOAD_FIFO_DEPTH=16384`；`awg_eth_bridge` 參數 `RX_FIFO_DEPTH=32768`、`TX_FIFO_DEPTH=16384`，`BUILD_ID` 由腳本傳入。QSFP2 腳位用 `constraints/eth/awg_eth_core.xdc`。
- `user_control` 照 v1 接 up_ 匯流排，取得 `config_done`。
- `tx_start_event`、`tx_play_word` 從 awg_tx 接到 awg_rx（`tx_play_word` 按 `doc/01` 用握手）。
- LED：led[0] = DAC 播放中且無 fault；led[1] = QSFP2 rx_aligned。

### 3. 模組修正

1. awg_rx：照 `doc/01` 新規定加 `tx_clk` 與 `xpm_cdc_handshake`，`h_cap_tx_word` 與實際播放位置誤差 ≤ 16 字（TB 量測並報告）。
2. awg_tx：64 深 LUTRAM CDC FIFO 改 `xpm_fifo_async`（`FIFO_MEMORY_TYPE "block"` 或 `"distributed"` 皆可，但讀出端必須先進暫存器才進打包器）。

### 4. 約束（`constraints/top/`）

- 腳位/板級 XDC：合併 D0 板級約束與光口 XDC，不得有衝突（同腳位、同 bank 電壓不一致要在報告指出）。
- 時序約束分兩個檔：
  - `timing.xdc`：只放純 XDC 指令（`create_clock`/`create_generated_clock`、clock groups）。
  - `cdc.tcl`：Tcl 寫的 CDC 約束（可用迴圈/proc），在建置腳本中以 `read_xdc -unmanaged` 或在 `opt_design` 前 `source` 載入。**XDC 檔內不准有 `proc`。**
  - 載入後腳本必須檢查每條 `set_max_delay -datapath_only`/`set_bus_skew` 實際命中的物件數 > 0，否則 `error`（D1R2 的教訓：約束靜默失效）。
- 允許的時序例外（每條在報告中列出依據）：host（`clk_pl_0`）↔ RF 時鐘、`clk_eth` ↔ host 的 `set_clock_groups -asynchronous`（前提：報告列出所有跨域點且都經 ASYNC_REG / xpm_cdc / 非同步 FIFO / 雙時鐘 BRAM 協定保護）；SYSREF 第一級 `set_max_delay -datapath_only`（照 D0R2）。dac↔tx、adc↔rx 不准有任何例外。
- RFDC IP 內部 12 個 CDC Critical（D0R2 已列出）用 `create_waiver` 逐條寫說明；不准 waive IP 以外的路徑。

### 5. 系統模擬（`sim/d3/`）

不含 RFDC 與 GT：TB 直接驅動 `awg_eth_bridge` 的 UDP app 介面（§4.1）與 `jtag_awg_axi` 側 AXI master 模型，下接 `axil_arb2` → `awg_control_v2` → `awg_tx`/`awg_rx`；DAC 輸出經固定延遲回環成 ADC 輸入（16 樣點/拍 @ dac_clk → 12 樣點/拍 @ adc_clk 的取樣率差用簡單模型處理，報告寫明模型）。

情境（固定）：
- S1 INFO/PING、ID/ABI/FS 暫存器讀值。
- S2 照 `doc/01` §6 載入流程：2 個通道各 4096 點、NOINC 寫 TX_WR_DATA、CRC 與 `sim/tx/crc_ref.py` 規則一致。
- S3 start 檢查：寫入不足時 start → SLVERR；執行中寫 TX_LENGTH/TX_WR_DATA → SLVERR。
- S4 擷取 trig_mode=1：arm → start → done → NOINC 讀 CAP_RD_DATA，回環資料與 TX 波形對齊比對（容許模型的固定延遲）；`CAP_TX_WORD` 合理。
- S5 擷取 trig_mode=0。
- S6 JTAG 與光口同時存取不死鎖、結果正確。
- S7 吞吐：光口 NOINC 寫 TX_WR_DATA 與讀 CAP_RD_DATA 各 64 KiB，報告 MB/s（host_clk 100 MHz），每個回覆 status 必須為 0。

### 6. 建置腳本（`scripts/d3/build_d3.tcl`，本任務只寫、只跑到 elaboration）

- 建 BD（`scripts/bd/create_system_v2.tcl`）、建 IP（jtag_awg_axi、光口 l_ethernet：沿用 E2 的 xci 匯入方式）、加 RTL/約束。
- 綜合、實現（預設策略，最多再 1 個替代策略）、`report_timing_summary`、`report_cdc`、`report_methodology`、`report_utilization`、`write_bitstream`、`write_hw_platform -include_bit`。
- 開頭 `set_param general.maxThreads 20`；`launch_runs` 用 `-jobs 2`。
- **本任務只執行到 `synth_design -rtl`（RTL elaboration）通過為止**，證明腳本、IP、BD、所有 RTL 能一起 elaborate；不要跑綜合與實現。

## 驗收（固定）

1. sim/tx T1–T6、sim/rx R1–R4 修改後重跑全 PASS（貼計數）。
2. awg_control_v2 單元 TB：暫存器表每一列至少一個正向與一個 SLVERR 檢查，全 PASS。
3. 系統模擬 S1–S7 全 PASS；S7 寫、讀各 ≥ 40 MB/s（目標 80，達不到時報告每字花費的 host_clk 週期分解：bridge / arb / control / awg_tx 背壓各佔多少）。
4. `synth_design -rtl` 0 error；BD 參數 diff `unexpected=0`；約束檔通過語法檢查（`read_xdc` 無 error、`cdc.tcl` 物件命中檢查通過，可在 elaborated design 上驗證能驗的部分）。
5. 資源估算表（從 OOC/前序報告彙整，非新跑）：URAM、RAMB36 等效、GT，對照 `doc/00` §7。
6. 同一失敗最多修 2 輪；仍失敗就停，報告 `NEEDS_PARENT_JUDGMENT`。
