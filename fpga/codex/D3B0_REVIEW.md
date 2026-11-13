# D3B0_REVIEW — 全晶片佈線前的只讀審查

先讀 `AGENTS.md`、`doc/00_ETH_PLAN.md`、`doc/01_DATAPATH_V2.md`、`reports/D3A6_INTEGRATION/report.md`（**最後的「Claude 審查判定」節**）、`reports/D0R2_TIMING/report.md`。

## 目的

D3A6（commit e2e9d25）已通過模擬和綜合。下一步 D3B 會跑實現、bitstream、XSA，要好幾個小時，而且產出要上板。
**開跑前先找出會讓實現失敗、時序不收斂、bitstream 產不出來或上板不能用的問題。**

本任務**只讀**：
- 不改任何 RTL、約束、腳本、TB、文件。
- 不跑 `opt_design` 之後的任何步驟：不跑 place、route，不產生 bitstream。
- 可以在 Vivado 裡打開 D3A6 的綜合網表，跑**只讀報告**。

## 可用的輸入

- 綜合網表：`build/D3A6_INTEGRATION/vivado/d0_clock_probe.runs/synth_1/awg_eth_top.dcp`
  （工程：`build/D3A6_INTEGRATION/vivado/d0_clock_probe.xpr`）
- 只准**複製**到 `build/D3B0_REVIEW/` 再開，不准改 D3A6 的 build 目錄。
- `open_checkpoint` 後先 `source constraints/top/cdc.tcl`（與 impl 的 OPT_DESIGN.TCL.PRE 相同）再出報告。
- D0R2 已上過一次 route：`reports/D0R2_TIMING/`（612.5 / 416.667 MHz 可收斂的證據）。
- 參考專案，唯讀：
  - `../rf_awg_scope_v1`：原 JTAG 版。
  - `D:\ClaudeProject\rf_udp_link_v3`：同一塊板、同一個 QSFP2 40G IP，已上板。

## 要審查的項目

### A. 實現與 bitstream 會不會被 DRC 擋下

1. 在綜合網表上跑：
   - `report_drc`（全部規則）
   - `report_methodology`
   - `report_io`
   - `report_utilization -hierarchical`（前 3 層）
2. 列出所有會擋下 `write_bitstream` 的 DRC，尤其是：
   - NSTD-1 / UCIO-1：沒設 IOSTANDARD、沒有 LOC 的埠。
   - 差分對、GT refclk 的 bank / 位置。
3. `board.xdc`：每一個頂層埠都要有 PACKAGE_PIN 和 IOSTANDARD（GT 埠除外）。
   - 與 `../rf_awg_scope_v1` 已上板的 XDC、v3 的 QSFP2 XDC 逐腳比對，列出不一致之處。
   - 特別看：QSFP2 refclk、GT quad、`qsfp2_reset_n` / `lpmode` / `modsel_n` 的腳位與預設電位、`pl_clk_p/n`、SYSREF。

### B. 時序風險（佈線前預判）

1. `report_timing_summary`（綜合後估計）：
   - 每個時鐘域的 WNS / TNS。
   - 最差 20 條路徑。
2. 拿 D3A6 和 D0R2 的結構比較，列出 D0R2 沒有、D3A6 新增、會跑在 612.5 / 416.667 / 306.25 / 312.5 MHz 的邏輯。至少看：
   - `tx_phase_tog` → `tog_q` → `first_half` → `dac_tdata_reg` 選擇器：扇出、`tog_q` 複本有沒有被合併、路徑深度。
   - `start_event` 與 CRC 相關的新邏輯。
   - RX gray 計數器。
   - 光口核心 312.5 MHz：對照 v3 的已收斂結果。
3. 列出邏輯級數 ≥ 4、或扇出 > 256 的高速域網路。
4. 判斷 D3B 需不需要：
   - pblock；
   - `phys_opt_design`；
   - 特定 directive（例如 `ExtraTimingOpt`、`AggressiveExplore`）。
   - 需要就給出具體指令和理由。

### C. 約束在實現階段是否完整、正確

1. `timing.xdc` 和 `cdc.tcl` 在 impl 流程中的載入順序與時機：
   - `STEPS.OPT_DESIGN.TCL.PRE`；
   - waiver 在 impl 會不會被保留。
2. `report_clocks`：
   - BUFGCE_DIV 衍生時鐘（tx_clk、rx_clk）是否被自動推導，週期是否正確；
   - GT txoutclk / rxoutclk 的週期。
3. `report_exceptions -ignored`：有沒有被覆蓋或無效的例外。
4. `report_clock_interaction`：再確認無 unsafe。列出每一組非同步群組的依據是否還成立。

### D. 建置腳本的實現段落（`scripts/d3/build_d3.tcl`、`run_build_d3.ps1`）

1. 讀 `DO_IMPLEMENTATION` 段落。現在只到 `route_design`，D3B 需要：
   - `write_bitstream`；
   - `write_hw_platform -fixed -include_bit`（XSA，給 F1 韌體用）；
   - post-route 報告：timing_summary、route_status、drc、methodology、power、clock_utilization、cdc。
   列出缺少什麼、哪裡會出錯（路徑、run 名稱、`wait_on_run` 失敗處理、輸出目錄是否落在 `build/<任務>/`）。
2. bitstream 屬性（壓縮、config 設定）與 `../rf_awg_scope_v1` 已上板的設定比對。
3. 工程名仍叫 `d0_clock_probe`，判斷是否影響 XSA / 韌體（不需要改就說不需要）。

### E. 上板相容性（不碰硬體，只看檔案）

1. **PS 設定**：BD 的 PS8 設定、RFDC 設定與已上板的 XSA 一致。
   - 引用 D3A6 的 `bd_param_diff.txt`，確認 unexpected = 0。
   - 列出刻意改過的參數（例如 DAC 9.8 G）。
2. **位址表**：AXI 位址表（awg_control_v2 `0x9020_0000`、RFDC 等）與下面三處一致：
   - `software/src`（韌體）；
   - `tools/awg_eth`（主機）；
   - `doc/01`。
3. **韌體**：`software/src/main.c` 中需要隨 v2 修改的地方，例如 `DAC_EXPECTED_RATE_GSPS 9.0` 應為 9.8，ADC 速率、取樣時鐘、插值。
   - 列出檔名:行號與建議值。
   - **不要改。**
4. **光口預設值**：MAC / IP / UDP port 的 RTL 預設值與 `tools/awg_eth` 主機工具一致（doc/00 §4 凍結）。
5. **時鐘與 reset 啟動順序**：
   - PS 開機 → clk_wiz locked → RFDC 起來 → `ps_config_done` → 資料路徑；
   - 光口 reset 不依賴 RFDC。
   - 找出會讓板子上電後卡住的相依關係。

### F. 其他

- `jtag_axi` 保留作為第二個 AXI master：確認仲裁在光口與 JTAG 同時存取時不會死鎖（看 `axil_arb2` RTL 與已跑過的 TB 覆蓋情況，不用新增 TB）。
- `report_power`（綜合後估計，預設環境）：總功耗、各主要部分。只報告，不判定。

## 輸出

`reports/D3B0_REVIEW/report.md`：

1. 發現清單，每條包括：
   - 嚴重度：`BLOCKER`（D3B 會失敗，或上板不能用）、`SHOULD`（建議在 D3B 前修）、`NOTE`。
   - 證據：檔名:行號，或報告片段，並附報告檔名。
   - 建議修法：只寫建議，不動手。
2. D3B 建議的實現參數：strategy / directive、`phys_opt`、pblock、`-jobs`，以及預估時間。
3. A–F 每一項都要有結論：沒問題就寫「已查，無問題」，並附依據。

另外寫 `status.json`：
- 每一項的 `PASS` / `ISSUES`；
- BLOCKER 數、SHOULD 數。

## 歸屬檔案

- `build/D3B0_REVIEW/**`、`reports/D3B0_REVIEW/**`
- **其他全部唯讀**，包括 `rtl/`、`constraints/`、`scripts/`、`sim/`、`software/`、`tools/`、`build/D3A6_INTEGRATION/`。

## 驗收（固定）

1. A–F 每一項都有結論與證據；數字都能在 `reports/D3B0_REVIEW/` 找到出處。
2. 實際跑過的 Vivado 報告檔都存在 `reports/D3B0_REVIEW/`。
3. `git status` 除了 `reports/D3B0_REVIEW/`，沒有任何被追蹤檔案改變。
4. 沒有跑 place、route、bitstream。
5. 不做任何硬體操作。最多 1 個頂層 Vivado 行程，`set_param general.maxThreads 20`。
6. 最後一則訊息以 `CODEX_TASK_DONE D3B0_REVIEW <PASS|ISSUES>` 開頭：`PASS` 表示 0 BLOCKER，否則用 `ISSUES`。
