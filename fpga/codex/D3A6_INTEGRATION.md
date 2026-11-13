# D3A6_INTEGRATION — 整合第六輪：DAC 半字相位、reset 域、CDC 收尾

先讀 `AGENTS.md`、`doc/01_DATAPATH_V2.md`、`reports/D3A5_INTEGRATION/report.md`（**最後的「Claude 審查判定」節**）。

## 目前狀態（Claude 已驗證，commit 835c7aa）

- 系統 TB `PASS=239 FAIL=5`，失敗全在 S4/S5。Claude 用監看信號實跑找到根因（見審查判定）。
- **S5：awg_tx RTL 錯。** `dac_phase` 自由翻轉，沒有對齊 tx_clk，每個 32 點字的前後 16 點會對調（看 reset 釋放落在哪個相位）。
- **S4：TB 延遲造成。** 回環模型延遲 1024 DAC 點。
- 另有 3 處 RTL/約束的 CDC 問題要修。
- **不要重寫已通過的部分。** 只做下面列出的項目。

本任務授權修改 `rtl/tx/awg_tx.sv`、`rtl/rx/awg_rx.sv`，**只限下面點名的地方**。

## 要做的

### 1. awg_tx DAC 半字相位（RTL 錯，最重要）

**要求**：任何 reset 釋放時機下，每個 tx 字都必須先在 dac_clk 上送 `[255:0]`（較早的 16 點），下一個 dac_clk 再送 `[511:256]`。start event 也一樣，要落在送前半的那一拍。

**做法（照做）**：
1. tx_clk 域加自由翻轉暫存器 `tx_phase_tog <= ~tx_phase_tog`（可複製以控制扇出）。
2. dac_clk 域：`tog_q <= tx_phase_tog`；`first_half = (tx_phase_tog != tog_q)`。
   - tx_clk 與 dac_clk 同源同相（BUFGCE_DIV ÷2），這條路徑本來就是同步計時的路徑，不需要同步器。
   - 推導：tx 字在 tx_clk 邊緣（同時是 dac 邊緣 E0）更新；dac 暫存器在 E1 第一次看到新字、在 E2 第二次看到；`tx_phase_tog` 在 E1 被看到變化、在 E2 不變。
3. `dac_phase`／`dac_phase_replica` 改成由 `first_half` 產生（各 replica 自己一份 `tog_q`，1 LUT 深度），取代自由翻轉。

**TX 單元 TB `sim/tx/tb_awg_tx.sv`**：
- 改成 tx_clk 由 dac_clk ÷2 產生（`always @(posedge dac_clk) tx_clk <= ~tx_clk;`），模擬 BUFGCE_DIV。
- 加一個新測試：`dac_resetn` 分別在 tx_clk 高、低兩種相位釋放，兩種情況 dac_tdata 序列都要與期望點序列逐點全等。
- 原有 T1–T6 全部保留且 PASS。

### 2. awg_tx 寫入 FIFO reset 域（CDC-1 ×9、tx_clk→clk_pl_0 unsafe）

- 現況：`fifo_reset = !host_resetn || !tx_resetn` 直接接 `wr_fifo_i`（XPM async FIFO，wr_clk = host_clk）的 `rst`。XPM 要求 `rst` 與 wr_clk 同步。
- 改法：`tx_resetn` 用 `xpm_cdc_async_rst` 同步到 host_clk，與 `host_resetn` 合併後在 host_clk 打一拍，才接 `rst`。
- 確認 reset 期間 wr_en 被擋住（看 `wr_rst_busy`），上電序列 TB 仍 PASS。

### 3. awg_rx 擷取計數跨域（CDC-10 ×10）

- 現況：`capture_word_gray_rx` 是組合邏輯（count ^ count>>1），直接進 `xpm_cdc_array_single`。
- 改法：改用 `xpm_cdc_gray`（`REG_OUTPUT=1`，src 側自帶暫存器）。或者在 rx_clk 先把 gray 打一拍，再進 `array_single` 並設 `SRC_INPUT_REG=1`。
- 確認計數只以 +1 前進。歸零只發生在 arm/abort（擷取尚未開始）；若有一次跳多步的路徑，在報告中說明 host 端只在 done 後讀，屬準靜態。

### 4. 約束與 waiver（`constraints/top/cdc.tcl`）

1. `user_control_i/config_done_reg → tx_i/ps_ready_sync_reg[0]`：單位元同步器，補 `set_max_delay -datapath_only`（目的時鐘週期）或 `set_false_path`，比照其他單位元同步器。印命中數。
2. RFDC IP 內部的 CDC-11 ×8（`rst_adc_clk`/`rst_rf_clk` → `usp_rf_data_converter_0/inst/cdc_*_clk_valid_i`）、CDC-13 ×4（`adc*_cmn_control_ff_reg → CONTROL_COMMON`）：
   - 用 `create_waiver -type CDC -id ... -from ... -to ... -description "..."`，說明「廠商 IP 內部」。
   - 每條印命中數。
3. `rst_ps8_0_99M` → `eth_core_i/u_eth_reset/arststages_ff_reg[0]/CLR` 與 GT reset controller（CDC-10 ×2）：
   - 查清楚同步器前是什麼組合邏輯。
   - 能在 RTL 外層（`awg_eth_top.v`）先打一拍就打一拍，否則附理由 waiver。
4. `check_timing`：
   - `dbg_hub` 造成的 no_clock 列為可接受（opt_design 才接時鐘），在報告中寫明個數。
   - 其餘 no_clock 與 unconstrained_internal_endpoints 3366 依階層分類列出前 10 大群組，判斷是否需要約束。需要的就補，不需要的說明。

### 5. 系統 TB（`sim/d3/tb_d3_system.sv`）

1. 回環模型延遲由 1024 改 128（`loop_A = dac_D − 128`）。距離斷言下限 64 不變。
2. compare_capture：從 `first_nonzero` 開始比對（S5 時 first_nonzero 應為 0），比對點數 = 1536 − first_nonzero，且至少 1400 點。
3. 判據：
   - S4 的 `first_nonzero ≤ 120`（128/1.96 + 管線 + 一拍 24 點），報告實際值。
   - 唯一 (o,p)、mismatches = 0。
   - S4 的 o 對起播位置報告換算（o 應接近 0 或一個小常數）。
4. `CAP_TX_WORD` 判據保留。

### 6. 生成路徑隔離

D3A5 執行時 Vivado 改寫了工程根目錄的 `rf_adda_loop.gen/`（已在 .gitignore）。查出原因（BD 副本仍指向根目錄的 gen 路徑？），讓 BD/IP 生成完全落在 `build/D3A6_INTEGRATION/`。不要刪除根目錄既有的 `rf_adda_loop.gen/`。

### 7. 重跑

1. TX/RX、control、bridge、系統 TB 全部重跑。
2. 工程模式 `synth_1 -jobs 2`，產生 clock_interaction、check_timing、report_cdc -details、utilization、ram_utilization。
3. **不跑實現、不產生 bitstream。**

## 歸屬檔案

- `rtl/tx/awg_tx.sv`（只限 §1、§2）、`rtl/rx/awg_rx.sv`（只限 §3）、`rtl/top/awg_eth_top.v`（只限 §4.3）
- `sim/tx/**`、`sim/d3/**`、`constraints/top/**`、`scripts/d3/**`、`scripts/bd/create_system_v2.tcl`（只限 §6 路徑）
- `build/D3A6_INTEGRATION/**`、`reports/D3A6_INTEGRATION/**`
- 其他全部唯讀。不准寫到其他任務的報告目錄；不准在工程根目錄留下新的 Vivado 輸出。

## 驗收（固定）

1. TX 單元 TB：原 T1–T6 加新的雙相位 reset 測試，全 PASS，0 mismatch。RX、control、bridge 全 PASS（貼計數）。
2. 系統 TB S1–S9 全 PASS，有 `RESULT ... FAIL=0`：
   - S4/S5 兩通道唯一 (o,p)、mismatches = 0，附 first_nonzero 與比對點數。
   - 回環距離斷言 0 違反。
   - S7 寫 ≥ 40、讀 ≥ 30 MB/s。
3. synth_1 0 error、0 critical warning。
4. `report_clock_interaction` 無 unsafe。
5. `report_cdc` 的 Critical：非 waiver 者為 0；waiver 逐條列出。
6. cdc.tcl 每條命中 > 0（貼數字）。
7. check_timing 分類表。
8. 資源表與 D3A5 對照（URAM 56、RAMB36 等效 269、GTY 4）。
9. 某一項同一失敗修 2 輪仍失敗：只停該項，其他繼續；status 寫 `NEEDS_PARENT_JUDGMENT` 並附證據。
10. 不做任何硬體操作。同時最多 3 個 Vivado 行程，`set_param general.maxThreads 20`。
