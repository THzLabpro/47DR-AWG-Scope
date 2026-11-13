# D3B_IMPL — 相位扇出修正 + 全晶片實現、bitstream、XSA

先讀 `AGENTS.md`、`doc/01_DATAPATH_V2.md`、`reports/D3B0_REVIEW/report.md`（佈線前審查，S1–S5）、`reports/D3A6_INTEGRATION/report.md`（最後的「Claude 審查判定」節）。

## 目前狀態（commit ed818e9）

- D3A6 模擬與綜合都已通過。
- 佈線前審查發現：
  - S1：`tx_phase_tog` / `tog_q` 扇出 1797，612.5 MHz 跨域路徑。原因是 32 份 `tog_q` 被綜合合併成 1 個。
  - S2：RX `adc_phase` 扇出 2690，而且自由翻轉。
  - S3：缺少 dbg_hub 約束。
  - S4：建置腳本沒有 bitstream / XSA 步驟。
- 本任務分兩段，**第一段沒全過就不准進第二段**。

授權修改 `rtl/tx/awg_tx.sv`、`rtl/rx/awg_rx.sv`，**只限下面點名的地方**。

## 第一段：RTL 修正與驗證

### 1. awg_tx DAC 半字相位：打一拍並複製（S1）

1. tx_clk 域：`tx_phase_tog_r[7:0]` 共 8 份，每份 `<= ~自己`，同一個 reset，加 `(* DONT_TOUCH = "TRUE" *)`。
2. dac_clk 域，以 `i = ch*4+blk` 為索引：
   ```
   (* DONT_TOUCH = "TRUE" *) reg [31:0] tog_q, fh_q;
   tog_q[i] <= tx_phase_tog_r[ch];
   fh_q[i]  <= (tx_phase_tog_r[ch] == tog_q[i]);   // 注意是 ==
   ```
3. 選擇信號改用 `fh_q[i]`：
   - `fh_q[i]=1` 送 `tx_word_reg[ch][blk*64 +: 64]`（前半）；
   - `fh_q[i]=0` 送 `[256+blk*64 +: 64]`（後半）。
   - start event 用 `fh_q[ch*4]`。
4. 推導（tx 邊緣 E0、E2；dac 邊緣 E0、E1、E2）：
   - E0 取樣時 tog 尚未翻轉、tog_q 也是舊值 → `fh_q=1`，E1 用它送前半。
   - E1 取樣 tog（新）≠ tog_q（舊）→ `fh_q=0`，E2 送後半。
   - 若單元 TB 顯示前後半顛倒，表示推導與實際時序不符：停下報告，**不要**改成 `!=` 了事。
5. 刪除 D3A6 的 `first_half` 組合邏輯與單一 `tx_phase_tog`。

### 2. awg_rx ADC 配對相位：對齊 rx_clk（S2）

1. 做法照 §1：
   - rx_clk 域 `rx_phase_tog_r[7:0]`，8 份，DONT_TOUCH。
   - adc_clk 域每通道一份：`rtog_q[ch] <= rx_phase_tog_r[ch]`，`ph_q[ch] <= (rx_phase_tog_r[ch] == rtog_q[ch])`，DONT_TOUCH。
2. 取代自由翻轉的 `adc_phase`：
   - `adc_pair_data_q` 通道 ch 在 `ph_q[ch]=1` 時更新（仍是 `{adc_tdata, adc_data_q}`）；
   - `adc_pair_valid_q` 在 `ph_q[0]=1` 時更新。
3. 結果：配對只在「非 rx 邊緣」的 adc 拍更新，rx_clk 在下一個 adc 拍取樣。
   - 跨域時序仍是 1 個 adc 週期，和現在相同。
   - 延遲固定，不隨開機改變。
4. 刪除 `adc_phase`。

### 3. dbg_hub 約束（S3）

照 `../rf_awg_scope_v1/constraints/timing.xdc`，在 `constraints/top/timing.xdc` 加入：

```
set_property C_CLK_INPUT_FREQ_HZ 100000000 [get_debug_cores dbg_hub]
set_property C_ENABLE_CLK_DIVIDER false [get_debug_cores dbg_hub]
set_property C_USER_SCAN_CHAIN 1 [get_debug_cores dbg_hub]
connect_debug_port dbg_hub/clk [get_nets <頂層 100 MHz host 時鐘網路>]
```

- 網路名請在綜合網表上查實際名稱（頂層是 `fclk_100m`），不要猜。
- 這四行必須放在 XDC（dbg_hub 在 opt_design 才建立）。

### 4. TB

1. **TX 單元 TB**（`sim/tx/tb_awg_tx.sv`）：保留 D3A6 的兩種 dac reset 相位測試，全部 PASS。
2. **RX 單元 TB**（`sim/rx/tb_awg_rx.sv`）：
   - `rx_clk` 改成 `always @(posedge adc_clk) rx_clk <= ~rx_clk;`。
   - 新增測試：`adc_resetn` 分別在 rx_clk 高、低兩種相位釋放。兩種情況下：
     - 擷取資料逐點全等；
     - 「觸發到第一個擷取點」的延遲（樣點數）相同。報告兩個延遲值。
   - 原有項目全部 PASS。
3. **系統 TB**：重跑，S1–S9 全 PASS，`FAIL=0`；S4/S5 唯一 (o,p)、0 mismatch。control、bridge TB 重跑 PASS。

### 5. 綜合與扇出核對

- 跑 `synth_1 -jobs 2`，0 error、0 critical warning。
- 在綜合網表上印出以下數字，寫進報告：
  - `tog_q`、`fh_q`、`rtog_q`、`ph_q` 的 cell 數：預期 32 / 32 / 8 / 8。
  - `tx_phase_tog_r`、`rx_phase_tog_r` 的 cell 數：各 8。
  - 每份 `tx_phase_tog_r` 的扇出（預期 ≤ 16）、每份 `fh_q` 的扇出（預期約 56）。
  - 若有複本被合併：停止，報告，不進第二段。
- 跑 `report_clock_interaction`，不得有 unsafe。
- 跑 `report_cdc`，非 waiver 的 Critical 必須為 0。

**第一段關卡**：§4 全部模擬 PASS，且 §5 全部符合，才進第二段。否則 status 寫 `NEEDS_PARENT_JUDGMENT` 並停止。

## 第二段：實現、bitstream、XSA

### 6. 建置腳本（`scripts/d3/build_d3.tcl`、`run_build_d3.ps1`）

1. 任務名稱參數化：build 用 `build/D3B_IMPL/`、reports 用 `reports/D3B_IMPL/`，不准寫入其他任務的目錄。BD 照 D3A6 的路徑隔離做法生成。
2. impl_1 設定：
   - **第一次**：預設策略，加上
     - `STEPS.PHYS_OPT_DESIGN.IS_ENABLED 1`、`STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore`；
     - `STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED 1`。
     - 依據：D0R2 用預設策略加 phys_opt 收斂，WNS +0.193。
   - `STEPS.OPT_DESIGN.TCL.PRE` = `cdc.tcl`，照 D3A6。
   - `launch_runs impl_1 -to_step write_bitstream -jobs 2`，然後 `wait_on_run`。
   - 檢查 run 的 `PROGRESS` 是否為 `100%`，`STATUS` 不得含 `ERROR`；失敗就停，附 log tail。
3. **時序不收斂的處理**（最多再兩次，每次換一組設定）：
   - 第 2 次：`Performance_ExplorePostRoutePhysOpt`。
   - 第 3 次：`Performance_ExtraTimingOpt`，並加 post-route phys_opt。
   - 三次都不收斂：停止，報告最差 20 條路徑與分類，status 寫 `NEEDS_PARENT_JUDGMENT`。
   - **不准**加 false_path、改時鐘、放寬約束。
4. route 完成後：
   - `open_run impl_1`；
   - `write_hw_platform -fixed -include_bit -force <build>/awg_eth_v2.xsa`；
   - 把 `.bit` 複製到 `build/D3B_IMPL/awg_eth_v2.bit`；
   - 印出兩個檔的 sha256。
5. post-route 報告，寫到 `reports/D3B_IMPL/`：
   - `report_timing_summary -max_paths 20`
   - `report_route_status`
   - `report_drc`
   - `report_methodology`
   - `report_power`
   - `report_clock_utilization`
   - `report_clock_interaction`
   - `report_cdc -details`
   - `report_utilization`
   - `report_ram_utilization`

## 歸屬檔案

- `rtl/tx/awg_tx.sv`（只限 §1）、`rtl/rx/awg_rx.sv`（只限 §2）、`constraints/top/timing.xdc`（只限 §3）
- `sim/tx/**`、`sim/rx/**`、`sim/d3/**`、`scripts/d3/**`
- `build/D3B_IMPL/**`、`reports/D3B_IMPL/**`
- 其他全部唯讀。不准在工程根目錄或 repo 根目錄留下新的 Vivado 輸出。

## 驗收（固定）

1. **第一段**：
   - TX（含兩種 dac reset 相位）PASS；
   - RX（含兩種 adc reset 相位，兩者延遲相同）PASS；
   - control、bridge PASS；
   - 系統 TB `RESULT ... FAIL=0`，S4/S5 唯一 (o,p)、0 mismatch；
   - 貼出所有計數。
2. 綜合 0 error、0 CW。複本 cell 數與扇出符合 §5。無 unsafe。CDC 非 waiver Critical 為 0。
3. **第二段**：
   - route 完成，`report_route_status` 無未繞線網路；
   - 所有時序 WNS ≥ 0、WHS ≥ 0、TNS = THS = 0，各域與跨域 WNS/WHS 列表，並與 D0R2 對照；
   - `report_drc` 0 error；
   - bitstream 與 XSA 存在，附 sha256；
   - XSA 內含 bit。
4. 資源表與 D3A6 對照，差異說明。
5. 某一項同一失敗修 2 輪仍失敗：只停該項，status 寫 `NEEDS_PARENT_JUDGMENT` 並附證據。
6. **不做任何硬體操作**：不下載 bit、不開 hw_server。同時最多 3 個頂層 Vivado 行程，`set_param general.maxThreads 20`。
