# D3A5_INTEGRATION 執行報告

日期：2026-11-11

狀態：`NEEDS_PARENT_JUDGMENT`

## 完成項目

- `sim/d3/tb_d3_system.sv`：改為 1 ps/1 fs 時間刻度，按 9.8/5 GS/s 建立 49/25 絕對樣點回環模型及距離斷言；加入逐點唯一波形、SV CRC 參考、S4/S5 的 `(o,p)` 搜尋與第一非零點報告。`udp_send`、`udp_receive`、`data_write` 保持未改；S7 仍用舊寫入任務。
- `rtl/tx/awg_tx.sv`：在 `tx_clk` 域增加 `crc_busy_tx` 暫存器，之後才送入 host 域同步器。
- `constraints/top/timing.xdc`：移除重複的 `pl_clk_p`、QSFP2 reference clock 定義及不支援的 Tcl 流程語句，保留純 XDC 設定。
- `constraints/top/cdc.tcl`：集中放置時鐘群組、單位元同步器例外、多位元匯流排 `set_max_delay -datapath_only` / `set_bus_skew`；規則以非零物件查詢驗證並輸出 65 筆命中紀錄。
- D3A5 執行流程：調整 `scripts/d3/build_d3.tcl`、`scripts/d3/run_build_d3.ps1`、`sim/d3/run_system_tb.ps1`、`sim/d3/run_tx_rx.ps1`、`sim/d3/run_control_tb.ps1`，輸出導向 D3A5 目錄；新增 `scripts/d3/run_eth_bridge.ps1`，避免寫入 D3A4 報告目錄。
- 報告、模擬日誌及綜合報告均位於 `reports/D3A5_INTEGRATION/`；綜合生成物位於 `build/D3A5_INTEGRATION/`。

## 固定驗收結果

1. **TX/RX、control、Ethernet bridge：PASS。** TX `PASS=26 FAIL=0`；RX `compared=543552 mismatches=0 x_count=0 pass_items=26 fail_items=0`，`CAP_TX_WORD` 最大誤差 17 字，小於 24 字；control `PASS=48 FAIL=0`；bridge `PASS=115 FAIL=0`，S10 為 65536 bytes、110464 cycles、`59.327926 MB/s`。
2. **系統 TB：FAIL，兩次完整執行皆 `PASS=239 FAIL=5`。** S1–S3、S6–S9 的其他檢查通過；S2 CRC ch0/ch1 分別為 `9FB469E2`、`7ACC79A3`，SV 參考函式亦核對 ch2 `55A06FF7`；S9 ch2 CRC `55A06FF7`，背壓 1609 cycles。回環距離斷言違反 0 次。S7 寫入 `45.768559 MB/s`（門檻 40），讀取 `34.087706 MB/s`（門檻 30）。
   - S4 ch0/ch1 均有 `captured[0]=0`，第一非零點索引為 471；第一段非零樣點映射到 TX wave sample 49。依固定搜尋法，無法由零值 `captured[0]` 找唯一 `o`，因此完整比較各報 1536 mismatches、無 `(o,p)` 解。擷取起始值 `CAP_TX_WORD=0`；首個非零點約在 wave sample 49（word 1），但不足以建立完整擷取的 `o` 或判定既有起播誤差。診斷序列在 wave sample 63 後跳回 33，需 Claude 判斷此管線延遲與資料序列行為。
   - S5 ch0/ch1 最佳候選皆 `(o=1605,p=7)`，但零 mismatch 解數為 0，各有 768/1536 mismatches。診斷映射開頭為 `1605,1607,1609,1611,1613,1615,1649,1651,1652,1654,1656,1658,1660,1662,1632,1634`，不是單一 `(o,p)` 序列。
   - S4 第一次執行的舊 `S4_START` 列印在 `o=-1` 時以整數除法留下了誤導的 `error_words=0`。TB 原始碼已修成無有效 `o` 時輸出 `-1`；此列印修正只做最終 xvlog 編譯驗證，未再跑完整模擬。判定不依賴該 `error_words=0`。
3. **工程模式綜合與約束：部分 PASS、整項 FAIL。** 最終 `synth_1 -jobs 2` 完成，`ERROR=0`、綜合 `CRITICAL WARNING=0`，本專案 build log 的 `CRITICAL WARNING` 數為 0；`timing.xdc` 不再有 clock 覆寫、位置參數或不支援 `if` 的警告。`report_clock_interaction` 仍有 host/`tx_clk` unsafe：`clk_pl_0→tx_clk` 1 個違例，WNS `-0.894 ns`；`tx_clk→clk_pl_0` 9 個違例，WNS `-1.454 ns`、TNS `-11.49 ns`。已定位代表路徑為 `user_control_i/config_done_reg` 到 `tx_i/ps_ready_sync_reg[0]`，以及 `tx_resetn_local_reg` 到 TX XPM FIFO reset-controller registers。依任務兩輪限制停止繼續改約束。
   - MAC `rxoutclk_out[0]→txoutclk_out[0]` 的 330 條路徑由已載入的 `optical_port2` IP XDC 設雙向 `3.2 ns` datapath-only max delay；時序表列為 `Ignored / Max Delay Datapath Only`，抽查路徑 slack `+2.686 ns`，端點為 IP 內 RAMD32 至 FDRE。已唯讀核對 v3 的 QSFP2 XDC/XPR 與 build Tcl；v3 專案自訂例外主要處理管理時鐘 restart 同步器，RX/TX 這組 3.2 ns 規則來自本次確認已載入的 L-Ethernet IP 自帶 XDC（`optical_port2.xdc` 第 75–78 行），不是整域 clock group。IP XDC 同時定義 6.4 ns QSFP2 reference clock，並確認已載入。`clk_pl_0` 10.0 ns 由 PS 定義；`pl_clk_p` 5.0 ns 由 D0 board XDC 定義；RFDC DAC/ADC clock wizard 分別為 1.633/2.400 ns，TX/RX 分頻時鐘為 3.266/4.800 ns。
   - `check_timing`：`no_clock=1132`、`unconstrained_internal_endpoints=3366`、`multiple_clock=0`、`generated_clocks=0`；no_clock 報告含 1124 個由 `dbg_hub/sl_iport0_o[1]` 標記的 JTAG debug pins，其餘端點及 unconstrained pin 清單保留在報告。固定驗收要求 no_clock/unconstrained 為零或逐項說明，故此項未通過。
   - `report_cdc -details` 尚有 34 個 Critical：CDC-1 9、CDC-10 13、CDC-11 8、CDC-13 4。`crc_busy_tx` 修正後，`tx_i/crc_busy_tx_reg→crc_busy_h1_reg` 已成為 2 級同步的 CDC-3 Info；剩餘 Critical 包含 RFDC vendor reset/硬巨集路徑、RX `capture_word_count` 跨域及 XPM FIFO reset 路徑。這些不在本任務允許的 RTL 修改範圍內。
   - `cdc.tcl` 的 65 筆命中均大於 0。時鐘物件：host 1、DAC pin/clock 2/1、TX 1、ADC pin/clock 2/1、RX 1、Ethernet TX/RX/management 1/1/2；clock group host/RF=1/3、host/Ethernet=1/4。CRC value、wrap、fault 匯流排為 32/32、32/32、8/8；TX write pointer 每通道 13/13；host→TX rewind/CRC channel/length/mask 為 3/3、3/3、13/13、8/8；各單位元同步器端點均 1/1。
4. **資源表：PASS，對照 D3A4 無 RAM/GTY 容量差異。** URAM 56；RAMB36 261 + RAMB18 16，等效 RAMB36=`261+16/2=269`；GTYE4_CHANNEL 4、GTYE4_COMMON 1。D3A4→D3A5：URAM 56→56、RAMB36 等效 269→269、GTY channel 4→4；CLB LUT 36882→36849（−33），CLB registers 63239→63236（−3）。
5. **需要 Claude 判定。** S4/S5 點序列比對仍不符；clock interaction 的 host/`tx_clk` unsafe、check_timing 非零端點及 34 個 CDC Critical 也未滿足固定門檻。未以放寬群組、false path 或判據掩蓋。
6. **硬體操作：未做。** 未下載 bitstream、未啟動 hw_server/JTAG、未向 `192.168.42.x` 發包；未執行實現或產生 bitstream。`synth_1` 同時最多 3 個 Vivado 行程限制及 `set_param general.maxThreads 20` 已依規執行。

## 執行命令

- `powershell -NoProfile -ExecutionPolicy Bypass -File sim/d3/run_tx_rx.ps1`：TX/RX PASS。
- `powershell -NoProfile -ExecutionPolicy Bypass -File sim/d3/run_control_tb.ps1`：`PASS=48 FAIL=0`。
- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/d3/run_eth_bridge.ps1`：`PASS=115 FAIL=0`。
- `powershell -NoProfile -ExecutionPolicy Bypass -File sim/d3/run_system_tb.ps1`：兩次均 `PASS=239 FAIL=5`；最後一次為診斷執行。
- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/d3/run_build_d3.ps1`：三次呼叫；最終一次 `EXIT_CODE=0`、`synth_design Complete!`、`ERROR=0`，CDC/timing 報告生成完成。前次分別暴露過寬的 cell glob 及無效 Q-pin 約束端點，已按兩輪限制修正；最終仍有上述未解違例。
- 最終 TB 原始碼編譯：`xvlog -sv -L xpm ... sim/d3/tb_d3_system.sv`，`EXIT_CODE=0`。
- `git diff --check`：PASS。

## 需要協調

- S4 起播同步擷取在波形到達前先保存 471 個零樣點，之後樣點序列亦出現跳轉；請 Claude 判斷既有「管線延遲」接受界線及資料路徑歸屬。
- S5 手動擷取的 wave-index 序列有跳轉，且兩通道皆 768/1536 mismatch；請依 `system_tb/system_xsim.log` 的 `CAPTURE_COMPARE`、`CAPTURE_TRACE` 與 `LOOP_MODEL_DISTANCE` 證據判定是否需授權檢查唯讀的 `awg_tx/awg_rx` 資料路徑。
- 為遵守多位元 CDC 不可被 clock groups 掩蓋，host/`tx_clk` 目前用逐點 bus timing/同步器例外，未放進整對 clock group。仍有 `config_done` 與 FIFO reset-controller 例外未收斂；另有 RX、RFDC 與 XPM CDC Critical 超出本任務可修改檔案範圍。
- check_timing 的 JTAG debug/no-clock 與 unconstrained internal endpoints 是保留 JTAG AXI/debug path 的結果；若固定驗收要全為零，需要上游決定 JTAG debug path 是否納入該項判據或授權修改其 IP/約束範圍。
- 工程根目錄原有 `rf_adda_loop.gen/`（檢查時 CreationTime 為 2026-11-11 13:18:49）；D3A5 Vivado 執行期間其 `system.bxml` 被更新，並有 IP 生成檔時間戳落在本次建置期間。此樹不在 D3A5 歸屬路徑，未刪除或手動還原，以免覆蓋先前工作；需協調將 BD/IP 生成路徑完全導向 `build/D3A5_INTEGRATION/`。

## Claude 審查判定（2026-11-11）

核對日誌：TX 26/26、RX 543552 點 0 錯、control 48/48、bridge 115/0、系統 TB `PASS=239 FAIL=5`；S2/S9 新 CRC 三值全對；回環距離斷言 0 違反；synth_1 0 error、0 critical warning；cdc.tcl 65 項皆 > 0。約束整理、crc_busy 打拍、MAC 330 條由 IP XDC 3.2 ns datapath-only 覆蓋的說明接受。

**S5 根因（Claude 加監看信號實跑，`build/CLAUDE_DBG/d3a5`）：awg_tx RTL 錯。** 擷取點對應的 TX 波形索引為 `1605..1615, 1649..1662, 1632..1646, 1680..1694, 1664..1679, …`：每個 32 點 tx 字在 dac_clk 上先送後半 16 點、再送前半。`awg_tx.sv` 的 `dac_phase`/`dac_phase_replica` 只在 `dac_resetn` 時設 1，之後自由翻轉，與 tx_clk（BUFGCE_DIV ÷2）相位**沒有任何對齊機制**；硬體上 reset 釋放落在哪個相位是隨機的，約一半開機會前後半段對調。TX 單元 TB 的 tx_clk 是獨立產生、碰巧對齊，所以沒抓到。RX 的 1:2 配對是 `{本拍, 前拍}`，順序與相位無關，沒有此問題。

**S4 開頭 471 個 0：TB 模型造成。** 模型 A = D − 1024，回環延遲 1024 DAC 點 ≈ 522 ADC 點，觸發後前 ~471 點資料尚未到達。改小延遲並從第一個非零點比對。

**剩餘 CDC/時序：**
- CDC-1 ×9 與 tx_clk→clk_pl_0 unsafe：`tx_resetn_local` 接到 `wr_fifo_i`（XPM async FIFO）的 `rst`，XPM 要求 rst 與 wr_clk 同域 → awg_tx RTL 錯。
- CDC-10 ×10：`awg_rx` `capture_word_count` 經組合邏輯進 `xpm_cdc_array_single` → 先打一拍（值只在 done 後讀，屬準靜態）。
- clk_pl_0→tx_clk unsafe：`config_done_reg → ps_ready_sync_reg[0]` 單位元同步器缺例外。
- CDC-11 ×8、CDC-13 ×4：RFDC IP 內部（`rst_*_clk` → `cdc_*_clk_valid_i`、`CONTROL_COMMON`）→ 廠商 IP，以 `create_waiver` 附理由。
- CDC-10 ×2：`rst_ps8_0_99M` → eth reset 同步器／GT reset controller → 核對後 waiver 或打拍。
- check_timing no_clock 1124 個為 `dbg_hub`（opt_design 才接時鐘），可接受；unconstrained_internal_endpoints 3366 需分類。

→ D3A6。
