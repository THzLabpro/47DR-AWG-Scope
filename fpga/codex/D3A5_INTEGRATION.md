# D3A5_INTEGRATION — 整合第五輪：回環模型、時序約束、crc_busy CDC

先讀 `AGENTS.md`、`doc/01_DATAPATH_V2.md`、`reports/D3A4_INTEGRATION/report.md`（**最後的「Claude 審查判定」節**）。

## 目前狀態（Claude 已驗證，commit ab3d3f3）

- bridge、正式頂層、工程模式綜合流程已接受。系統 TB `PASS=238 FAIL=4`，失敗全在 S4/S5，原因是 TB 回環模型（不是 RTL）。
- `timing.xdc` 的兩組 `set_clock_groups` 沒有生效，`tx_clk↔clk_pl_0` 有 unsafe 違例路徑。
- **不要重寫已通過的部分。** 只做下面列出的項目。

## 要做的

### 1. 系統 TB 回環模型（`sim/d3/tb_d3_system.sv`）

現況錯誤：DAC 側每個 dac_clk 寫 16 點（9.8 GS/s），ADC 側每個 adc_clk 讀 12 點（5 GS/s），65536 點環形緩衝約 13.6 µs 被追尾覆寫。

改法（照做，不要自創別的模型）：

1. TB 改 `timescale 1ps/1fs`；`adc_clk` 週期 2400 ps，`dac_clk` 週期 1632.6531 ps（9.8/5 = 1.96 = 49/25；`tx_clk`、`rx_clk` 照舊由 ÷2 產生）。核對其他時鐘不受影響。
2. DAC 歷史：每個 dac_clk 邊緣（不論 tvalid）把 16 點寫入 `dac_hist[ch][D % 65536]`，D 為絕對樣點計數，+16。
3. ADC 取樣：ADC 絕對樣點 n（每拍 +12）取 `dac_hist[ch][(A + (n*49)/25) % 65536]`，整數除法（零階保持）。A 在模型啟動時設為「當時的 D − 1024」。
4. 每拍斷言 `64 ≤ D − (A + (n*49)/25) ≤ 60000`，違反就 `FAIL` 並印數值，不得靜默。
5. 低 2 bit 照舊補 0。

### 2. 測試波形改成逐點唯一

現況的「字 = base + k」高半字固定，低半字每 4 字相同，偏移搜尋有歧義。改成：

- 通道 c、樣點 s（0..4095）：`int16 = ((s*0x2F1 + c*0x1234 + 0x155) mod 16384) << 2`。字 k = `{sample(2k+1), sample(2k)}`（`[15:0]` 先）。4096 點內數值互不相同。
- 新增寫入任務（例如 `data_write_wave(ch, first_word, count)`），**不要改** `udp_send`、`udp_receive`、`data_write`（S7 吞吐仍可用舊的 data_write）。
- CRC 期望值（Claude 已按 `sim/tx/crc_ref.py` 規則用此公式算出，4096 點）：ch0 `9FB469E2`、ch1 `7ACC79A3`、ch2 `55A06FF7`。S2 與 S9 改用新期望值；S9 寫哪個通道就用哪個值。TB 內也要有一個 SV 函式按同規則計算 CRC，與常數互相核對。

### 3. S4/S5 比對

- 讀回的 captured[i]（i = 0..N−1，N ≥ 1536）應等於 `tx_wave[(o + (i*49 + p)/25) mod L]`，L = TX_LENGTH×32，p ∈ [0,25)、o ∈ [0,L) 未知。
- 解法：用 captured[0] 在 tx_wave 中找唯一 o0；對 p = 0..24 試 `o = o0 − p/25`（整數），全部 N 點相符者為解。報告 o、p、mismatches。
- 判據：存在唯一 (o,p) 使 mismatches = 0。S4（trig_mode=1）另報 o 與起播的關係，`CAP_TX_WORD` 誤差 ≤ 24 字的既有判據保留。
- 若 captured 開頭是 0（擷取早於資料到達），先報告第一個非零點的索引。trig_mode=1 時這可能是合理的管線延遲；由 Claude 判定，不要改判據來迴避。

### 4. `awg_tx` crc_busy CDC（授權修改 `rtl/tx/awg_tx.sv`，只限這一處）

`report_cdc` CDC-10 Critical：`FSM_onehot_state_reg[3]` 經組合邏輯進 `crc_busy_h1_reg`。在 tx_clk 域加一級暫存器 `crc_busy_tx` 後才進同步器。重跑 `sim/d3/run_tx_rx.ps1`，TX 26/26、RX 全 PASS。

### 5. 時序約束

1. `constraints/top/timing.xdc`：
   - 只留純 XDC，不能有 `if`、`set` 變數、`proc`。
   - `pl_clk_p`、`qsfp2_refclk` 若 BD/IP 已定義（綜合 log 有 18-619 覆寫、18-1056 完全覆蓋），就刪掉自己的 `create_clock`；在報告中列出由誰定義、週期多少。
2. 時鐘群組與 CDC 例外全部放 `cdc.tcl`（綜合後、opt_design 前載入），每條都印命中數且 > 0：
   - `clk_pl_0` vs {dac clk_wiz、tx_clk、adc clk_wiz、rx_clk}：非同步。
   - `clk_pl_0` vs eth（txoutclk/rxoutclk 與管理時鐘）：非同步。
   - 若有多位元匯流排跨域不是經 xpm/握手（例如 `crc_value_tx→crc_value_host` 的使能擷取），改用 `set_max_delay -datapath_only`（目的時鐘週期）加 `set_bus_skew`，不要用 groups 蓋掉。
3. MAC 內 `rxoutclk_out[0]_1 → txoutclk_out[0]_1` 330 條 unsafe：
   - 核對 `D:\ClaudeProject\rf_udp_link_v3` 同一 IP 的約束（`constraints/`、`vivado/` 下 impl 的 Tcl），以及 IP 自帶 XDC 是否有載入。
   - 補齊 v3 已上板驗證過的同等約束，或證明這些是 IP 內部同步器（列端點）。
4. 重跑工程模式 `synth_1 -jobs 2`，然後檢查：
   - 由本專案 XDC/Tcl 引起的 CRITICAL WARNING 為 0。
   - `report_clock_interaction` 中不得有 `unsafe`，也不得有跨時鐘域的 Timed 違例。每一條非 Clean 的列出原因。
   - `check_timing` 的 no_clock、unconstrained_internal_endpoints、multiple_clock 為 0，或逐項說明。
   - `report_cdc -details` 不得有 Critical。
5. **不跑實現、不產生 bitstream。**

## 歸屬檔案

- `sim/d3/**`、`rtl/tx/awg_tx.sv`（只限 §4）、`constraints/top/**`、`scripts/d3/**`
- `build/D3A5_INTEGRATION/**`、`reports/D3A5_INTEGRATION/**`
- 其他全部唯讀，`D:\ClaudeProject\rf_udp_link_v3` 只讀。不准寫到其他任務的報告目錄；不准在工程根目錄留下 Vivado 輸出檔。

## 驗收（固定）

1. `run_tx_rx.ps1`、`run_control_tb.ps1`、`sim/eth_bridge` 全 PASS（貼計數）。
2. 系統 TB S1–S9 全 PASS，有 `RESULT` 行：
   - S4/S5 兩通道 mismatches = 0，附 (o,p)。
   - 回環模型距離斷言 0 次違反。
   - S2/S9 CRC 等於新期望值。
   - S7 寫 ≥ 40、讀 ≥ 30 MB/s。
3. synth_1 0 error；本專案約束 CRITICAL WARNING = 0；clock_interaction 無 unsafe；report_cdc 無 Critical；cdc.tcl 每條命中 > 0（貼數字）。
4. 資源表與 D3A4 對照（URAM 56、RAMB36 等效 269、GTY 4），差異說明。
5. 某一項同一失敗修 2 輪仍失敗：只停該項，其他繼續；status 寫 `NEEDS_PARENT_JUDGMENT`。
6. 不做任何硬體操作。同時最多 3 個 Vivado 行程，`set_param general.maxThreads 20`。
