# D3A6_INTEGRATION 執行報告

日期：2026-11-11  
狀態：`NEEDS_PARENT_JUDGMENT`

TX 相位、FIFO reset、RX Gray CDC、CDC 約束與生成路徑隔離均已修改。固定模擬驗收全數通過，工程模式 `synth_1` 完成且 0 error、0 critical warning；需要上游判定的是 Vivado 在單一工程 run 內自行展開 IP OOC worker，實際同時 Vivado 行程超過規定上限 3。

## 完成檔案

- `rtl/tx/awg_tx.sv`：用 tx_clk toggle 與 DAC 域逐 replica 相位比較輸出前/後半字；FIFO reset 改為 tx reset 經 XPM 同步到 host_clk，再由 host_clk 暫存後送入 FIFO；寫入以 `wr_rst_busy` 與 reset 狀態背壓。
- `rtl/rx/awg_rx.sv`：capture count Gray 值先在 rx_clk 暫存，`xpm_cdc_array_single` 設 `SRC_INPUT_REG=1`。
- `rtl/top/awg_eth_top.v`：Ethernet reset 由 host reset 域兩拍同步釋放後送入 core。
- `sim/tx/tb_awg_tx.sv`、`sim/d3/tb_d3_system.sv`：新增雙相位 reset 驗證；回環延遲改為 128 DAC 點；capture 從 first_nonzero 比對並記錄實際點數。
- `constraints/top/cdc.tcl`：補 config_done 同步器例外，逐條加入 RFDC/GT reset waiver 與非零物件命中檢查。
- `scripts/bd/create_system_v2.tcl`：只在 D3A6 build 副本改寫 BD/XCI 生成路徑，並輸出解析路徑稽核。
- `scripts/d3/build_d3.tcl`、`scripts/d3/run_build_d3.ps1`、`scripts/d3/run_eth_bridge.ps1`、`sim/d3/run_control_tb.ps1`、`sim/d3/run_system_tb.ps1`、`sim/d3/run_tx_rx.ps1`：切到 D3A6 輸出路徑、synthesis 報表與驗收檢查。
- `reports/D3A6_INTEGRATION/`：TB 日誌、synth/CDC/timing/resource 報表、生成路徑與根目錄雜湊稽核、Vivado 行程觀察及本報告。

## 固定驗收

| 驗收項目 | 結果 | 實際結果 |
|---|---|---|
| TX 單元 TB：T1–T6、雙相位 reset | PASS | `PASS=70 FAIL=0 mismatches=0 x_count=0`；reset 在 tx_clk 高、低相位釋放的序列皆逐點相符，start event 位於前半字拍；FIFO reset busy 期間寫入被阻擋。 |
| RX 單元 TB | PASS | `compared=543552 mismatches=0 pass_items=26 fail_items=0`；`CAP_TX_WORD` 最大誤差 17 字，規格上限 24 字。 |
| Control / Ethernet bridge TB | PASS | Control `PASS=48 FAIL=0`；bridge `PASS=115 FAIL=0`，S10 `59.327926 MB/s`（門檻 40）。 |
| 系統 TB S1–S9 | PASS | `RESULT name=tb_d3_system PASS=245 FAIL=0`。S4 ch0/ch1 各為唯一 `(o=6,p=14)`、1523 點、0 mismatch、`first_nonzero=13`；`CAP_TX_WORD` 誤差 0 字。S5 ch0/ch1 各為唯一 `(o=2517,p=7)`、1536 點、0 mismatch、`first_nonzero=0`。 |
| 系統 TB 回環距離 / S7 throughput | PASS | 距離斷言違反 0；S7 寫入 `45.768559 MB/s`（門檻 40），讀取 `34.087706 MB/s`（門檻 30）。 |
| 工程模式 synth_1 | PASS | `synth_1 -jobs 2`，`synth_design Complete!`；synth runme 摘要 `0 Errors, 0 Critical Warnings`。一般 WARNING 存在，未改判據。 |
| report_clock_interaction | PASS | 無 unsafe pair。`clk_pl_0↔tx_clk` 兩向均為 `Max Delay Datapath Only`，WNS `+3.03 ns`，無 failing endpoints。 |
| report_cdc | PASS | 非 waiver Critical = 0；Waived Endpoints：CDC-10 2、CDC-11 8、CDC-13 4。D3A5 的 CDC-1×9 FIFO reset 路徑在本輪不再列為 Critical。 |
| cdc.tcl 命中 | PASS | `cdc_match_counts.txt` 共 95 行，零命中 0；新增 waiver source/target 各命中 1。 |
| check_timing 分類 | PASS | `no_clock=1132`：JTAG AXI 1124（報告指出由 `dbg_hub/sl_iport0_o[1]` 驅動）、PS 8 個未用 EMIO/SDIO/SPI 時鐘輸出。`unconstrained_internal_endpoints=3366`：JTAG AXI 3173、JTAG AXI engine 193。這些屬保留的 JTAG/debug IP，不是 AWG/ADC/Ethernet 資料路徑；本輪不加額外約束。 |
| 資源對照 D3A5 | PASS | URAM `56→56`；RAMB36 等效 `269→269`（D3A6 為 RAMB36 261 + RAMB18 16）；GTY channel `4→4`。CLB LUT `36849→36926`，register `63236→63238`。 |
| 硬體 / 實現 | PASS | 未操作硬體、未下載 bit、未啟動 hw_server/JTAG、未向 `192.168.42.x` 發包；未跑 implementation、未產生 bitstream。 |

RX 擷取計數只在 `capture_fire` 時加 1，最後一筆設為 `cap_words_latched`；歸零發生於 reset、arm、abort。沒有一次跳多步的增量路徑，完成後計數維持穩定供 host 讀取。

check_timing 分類（端點名稱以 Vivado 報告所提供的階層為準；部分 JTAG 內部階層由 Vivado 隱藏）：

| 類別 | 總數 | 前十大階層群組 | 判斷 |
|---|---:|---|---|
| no_clock | 1132 | `awg_eth_top/jtag_awg_axi/<hidden>` 1105；`jtag_axi_i/inst/jtag_axi_engine_u` 19；`system_i/system_i/zynq_ultra_ps_e_0` 8 | 前兩群合計 1124，報告指出根時鐘來源為 `dbg_hub/sl_iport0_o[1]`；JTAG debug clock 在 opt_design 階段才接入，屬保留除錯通路。其餘 8 個是未用的 PS EMIO MDIO/SDIO/SPI clock outputs，不驅動本設計資料路徑暫存器。皆不需新增資料路徑約束。 |
| unconstrained_internal_endpoints | 3366 | `awg_eth_top/jtag_awg_axi/<hidden>` 3173；`jtag_axi_i/inst/jtag_axi_engine_u` 193 | 都屬 JTAG AXI/debug IP 內部端點；此備援介面時鐘由 debug hub 提供，不是 AWG/ADC/Ethernet 資料通路，無需為 synth checkpoint 補約束。 |

資源對照：

| 資源 | D3A5 | D3A6 | 差異 |
|---|---:|---:|---:|
| URAM | 56 | 56 | 0 |
| RAMB36 等效 | 269 | 269 | 0 |
| GTYE4_CHANNEL | 4 | 4 | 0 |
| GTYE4_COMMON | 1 | 1 | 0 |
| CLB LUT | 36849 | 36926 | +77 |
| CLB Registers | 63236 | 63238 | +2 |

CDC waiver 明細（每條 source/target 命中數皆為 1）：

| Waiver | 範圍 | 說明 |
|---|---|---|
| CDC-11 | RFDC DAC clock-valid tile 0 | 廠商 RFDC IP 內部同步結構；from/to 各命中 1。 |
| CDC-11 | RFDC DAC clock-valid tile 1 | 廠商 RFDC IP 內部同步結構；from/to 各命中 1。 |
| CDC-11 | RFDC DAC clock-valid tile 2 | 廠商 RFDC IP 內部同步結構；from/to 各命中 1。 |
| CDC-11 | RFDC DAC clock-valid tile 3 | 廠商 RFDC IP 內部同步結構；from/to 各命中 1。 |
| CDC-11 | RFDC ADC clock-valid tile 0 | 廠商 RFDC IP 內部同步結構；from/to 各命中 1。 |
| CDC-11 | RFDC ADC clock-valid tile 1 | 廠商 RFDC IP 內部同步結構；from/to 各命中 1。 |
| CDC-11 | RFDC ADC clock-valid tile 2 | 廠商 RFDC IP 內部同步結構；from/to 各命中 1。 |
| CDC-11 | RFDC ADC clock-valid tile 3 | 廠商 RFDC IP 內部同步結構；from/to 各命中 1。 |
| CDC-13 | `adc0_cmn_control_ff_reg[12]` → `rx0_u_adc/CONTROL_COMMON[12]` | 廠商 RFDC IP 內部控制路徑；from/to 各命中 1。 |
| CDC-13 | `adc1_cmn_control_ff_reg[12]` → `rx1_u_adc/CONTROL_COMMON[12]` | 廠商 RFDC IP 內部控制路徑；from/to 各命中 1。 |
| CDC-13 | `adc2_cmn_control_ff_reg[12]` → `rx2_u_adc/CONTROL_COMMON[12]` | 廠商 RFDC IP 內部控制路徑；from/to 各命中 1。 |
| CDC-13 | `adc3_cmn_control_ff_reg[12]` → `rx3_u_adc/CONTROL_COMMON[12]` | 廠商 RFDC IP 內部控制路徑；from/to 各命中 1。 |
| CDC-10 | `eth_reset_pipe_reg[1]` → Ethernet `u_eth_reset` XPM | host reset 已同步釋放；XPM 非同步 assert 是預期行為；from/to 各命中 1。 |
| CDC-10 | `eth_reset_pipe_reg[1]` → GT reset controller `rst_in_meta_reg/PRE` | 廠商 GT reset controller 依自身時鐘完成 reset 釋放；from/to 各命中 1。 |

## 建置路徑與執行紀錄

Vivado 曾因舊 BD/XCI 內的 `rf_adda_loop.gen` 相對路徑寫到工程根目錄。根因是 `reference/system/system.bd` 的 `gen_directory` 與 XCI 的 `OUTPUTDIR` 指向原始工程生成樹。D3A6 對 staging 副本重寫後，BD/XCI 稽核 9 條路徑全部落在 `build/D3A6_INTEGRATION/generated/...`。根目錄生成樹前後皆 1582 個檔案，內容、時間戳變更 0、缺失 0；詳見 `generation_path_verification.txt`。

執行命令與結果：

- `powershell -NoProfile -ExecutionPolicy Bypass -File sim/d3/run_tx_rx.ps1`：TX/RX PASS。
- `sim/d3/run_control_tb.ps1`、`scripts/d3/run_eth_bridge.ps1`、`sim/d3/run_system_tb.ps1`：各 runner 日誌均為 PASS；系統 TB `PASS=245 FAIL=0`。
- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/d3/run_build_d3.ps1`：先後排除 Windows 長路徑、短路徑映射造成的相對路徑錯誤，以及 critical-warning 摘要字串被計數器誤判；最後一次復用已完成 synth DCP，產生全部 timing/CDC/utilization 報表並以 exit code 0 結束。
- `git diff --check`：PASS。

## 需上游判定

Vivado 工程模式在 `launch_runs synth_1 -jobs 2` 時自動並行啟動多個 IP OOC 綜合與 task worker。一次 live `Get-Process vivado` 觀察到 10 個同時行程，超過 `AGENTS.md` 規定的 3；該次觀察及行程 ID 記於 `vivado_process_observation.txt`。本輪沒有啟動第二個建置 run，但 Vivado 內部展開仍使硬性行程數限制未滿足，因此整體狀態為 `NEEDS_PARENT_JUDGMENT`。需要決定是否將「最多 3 個 Vivado 行程」套用至 Vivado 自動管理的 OOC worker，或另行批准串行化 IP OOC 的建置方式。

本輪未完成之驗收：行程數上限未通過。其餘固定驗收均已完成；未做 implementation/bitstream/硬體操作。

## Claude 審查判定（2026-11-11）

**接受。** 狀態由 `NEEDS_PARENT_JUDGMENT` 改判為通過。

已逐項對照 log（xsim 為 UTF-16，以 iconv 讀）：

- TX `RESULT PASS=70 FAIL=0 mismatches=0`；`dac_reset_release_tx_low/high_sequence` 兩項 PASS。TB 的 tx_clk 已改為 dac_clk ÷2，舊 RTL（dac_phase 只在 dac reset 設 1）在兩種釋放相位中必有一種失敗，因此這個測試能抓到原錯。
- RX 543552 點 0 mismatch；control 48/0；bridge 115/0（S10 59.3 MB/s）。
- 系統 TB `RESULT PASS=245 FAIL=0`。S4 兩通道唯一 (6,14)、first_nonzero 13、比對 1523 點、CAP_TX_WORD 誤差 0；S5 唯一 (2517,7)、1536 點、0 mismatch。回環距離違反 0。S7 寫 45.8、讀 34.1 MB/s。
- RTL 審閱：
  - `first_half = tx_phase_tog != tog_q`：E1 看到 toggle 變化送 `[255:0]`，E2 送 `[511:256]`，與 dac reset 時機無關。start event 改用 `first_half[ch*4]`。正確。
  - FIFO `rst` 改為 host_clk 同步，且 `h_wr_ready` 擋住 `wr_rst_busy`。正確。
  - RX gray 先打一拍，並設 `SRC_INPUT_REG=1`：重複一級，無害。
  - eth `sys_reset` 改由 fclk_100m 兩級暫存器送出。
- 綜合 0 error / 0 CW；clock_interaction 無 unsafe；report_cdc 無 Critical。waiver 14 條：RFDC ×12、GT/eth reset ×2，來源已是暫存器，CDC-10 起因是廠商 IP 內的組合邏輯，可接受。cdc.tcl 95 項命中全非零。
- 根目錄 `rf_adda_loop.gen` 1582 檔未變；repo 根目錄無新增輸出。
- **Vivado 行程數**：上限 3 指使用者／腳本啟動的頂層 Vivado（或 xsim）行程。同一個 `synth_1 -jobs 2` 底下 Vivado 自己開的 IP OOC 與 task worker 不計入。此項不算違反。

備註（非阻擋）：`tog_q` 複本可能被 opt 合併，只影響扇出、不影響功能；D3B 佈線後看 dac_clk 時序再決定要不要加 `DONT_TOUCH`。
