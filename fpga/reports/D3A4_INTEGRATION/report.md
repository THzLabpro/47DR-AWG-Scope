# D3A4_INTEGRATION 執行報告

日期：2026-11-11

狀態：`NEEDS_PARENT_JUDGMENT`

## 完成項目

- `rtl/eth/awg_eth_bridge.sv`：還原 `payload_mem` 單一同步讀口，以首字讀取和奇數字 W 握手預取下一個 qword；READ 收到 R 後直接發下一個 AR；加入最大請求/回覆 FIFO 容量 elaboration 檢查。
- `rtl/top/awg_eth_top.v`：正式 bridge 的 `TX_FIFO_DEPTH` 改為 32768。
- `sim/eth_bridge/tb_eth_bridge.sv`：S10 固定門檻由 80 改為 40 MB/s；其他 bridge 判據未改。
- `sim/d3/tb_d3_system.sv`：加入雙通道 CRC/TX_WR_PTR、S4/S5 擷取讀回比對、S8 abort/rearm、S9 隨機 ready 背壓與 S7 分段讀回/週期計數。既有 `udp_send`、`udp_receive` 保持不變。
- `scripts/d3/build_d3.tcl`、`scripts/d3/run_build_d3.ps1`：改為 D0 工程模式，從 D3A4 隔離 BD 副本建 XPR、匯入 E2/JTAG IP、執行 `synth_1 -jobs 2`，產生綜合後報告；實現流程由 `DO_IMPLEMENTATION=0` 關閉。
- `constraints/top/cdc.tcl`：要求同步器端點與時鐘物件非零命中；綜合網表上的 QSFP2 時鐘群組使用報告中的 GT `txoutclk_out` clock object。
- D3A4 執行腳本把模擬產物放在 `build/D3A4_INTEGRATION/`，日誌與報告放在 `reports/D3A4_INTEGRATION/`。

## 固定驗收結果

1. Ethernet bridge S1–S11：`RESULT name=tb_eth_bridge PASS=115 FAIL=0`。S10 為 65536 bytes、110464 host cycles、`59.327926 MB/s`，高於 40 MB/s 門檻；80 MB/s 只列為目標。
2. TX/RX 與 control：
   - TX：`PASS=26 FAIL=0 mismatches=0 x_count=0`。
   - RX：`compared=543552 mismatches=0 x_count=0 pass_items=26 fail_items=0`；abort/rearm 通過，`CAP_TX_WORD` 最大誤差 17 字，小於 24 字。
   - control：`PASS=48 FAIL=0`。
3. 系統 TB：`RESULT name=tb_d3_system PASS=238 FAIL=4`，因此 S1–S9 未全 PASS。
   - S2 ch0 CRC `9014BEF6`、ch1 CRC `65FFA182`；兩通道 `TX_WR_PTR=4096`，CRC 前輪詢 STATUS bit8 已清零。
   - S8 abort、busy 時 `CAP_RD_DATA` 回 AXI_ERR、abort 後 rearm 通過。
   - S9 隨機背壓觀察到 1668 cycles；回讀 CRC 為 `9014BEF6`，`TX_WR_PTR=4096`。
   - S4 capture 長度 1536 samples，S4 `CAP_TX_WORD=0`、TB 推得起始位置誤差 2 words；但兩通道逐點比較各有 768 mismatches，未通過。
   - S5 capture 長度 1536 samples；兩通道逐點比較各有 384 mismatches，未通過。
   - S7 寫：65536 bytes、143190 cycles、`45.768559 MB/s`。週期分解：bridge 61270（3.7396/word）、arb 16384（1.0000/word）、control 65536（4.0000/word）、awg_tx 0。
   - S7 讀：65536 bytes、192260 cycles、`34.087174 MB/s`。週期分解：bridge 77572（4.7346/word）、arb 16384（1.0000/word）、control 65536（4.0000/word）、awg_rx 32768（2.0000/word）。每個回覆 status=0，讀取範圍位於 32784 samples 的有效擷取內，首包含非零樣點。
4. 工程模式全晶片綜合：`synth_1` 為 `synth_design Complete!`，`runme.log` 的 `ERROR:` 計數為 0。CDC 在綜合後網表執行，每個匹配數皆大於 0：SYSREF DAC/ADC source 與 stage1 各 1，DAC/ADC clock pin 各 2、clock 各 1，host/eth clock group 各 1。BD diff `changed=15`、`unexpected=0`。
5. 綜合資源實數（`utilization_synth.rpt`）：URAM 56/80；RAMB36 261 + RAMB18 16（等效 RAMB36 = 261 + 16/2 = 269，Block RAM tile 269/1080）；CLB LUT 36882；CLB registers 63239；GTYE4_CHANNEL 4、GTYE4_COMMON 1。`doc/00_ETH_PLAN.md` §7 預估 TX URAM 56 塊、RX 約 224 個 RAMB36；總 RAMB36 等效 269，包含 RX、Ethernet/JTAG FIFO 與其他區塊。Vivado 顯示 GTYE4_CHANNEL 總數 8（4 used、4 fixed），而工程文件 §6 列器件 GTY 16；此資源口徑差異需 Claude 核對。

## RAM 推斷與 FIFO 計算

- `report_ram_utilization` 將 `eth_bridge_i/payload_mem` 識別為 `RAM_SDP`、1024x64，拆成兩個 RAMB36E2，RAM_STYLE 為 `BLOCK`；RTL 只有 `payload_rd_data <= payload_mem[payload_rd_addr]` 一個同步讀口。
- TX 的 `tx_i/g_uram_channel[0].g_uram_block[0]` 為 URAM288，讀寫 OREG A/B 均為 1。RX 的 `rx_i/channel_bram[0].capture_mem` 推為 BLOCK RAMB36E2。
- bridge 最大封包：`MAX_BYTES=24+4*2048=8216` bytes；需要 `1+ceil(8216/8)=1028` 個 128-bit FIFO 格，至少 `1028*16=16448` bytes。正式 bridge 設 32768 bytes，即 2048 格；RX 同為 32768 bytes，容量足夠。Elaboration 檢查對 TX/RX 都已加入。
- core FIFO 的 RTL 將 `DEPTH` 直接用作 entry 數：RX 32768、TX 16384 個 256-bit beats；最大 9000-byte MTU 加 L2 header 約 282 beats，兩者皆足夠。checksum payload FIFO 為 16384 個 64-bit beats；最大 8216-byte UDP payload 需 1027 beats，亦足夠。core 參數維持原值。

## 執行命令

- `powershell -NoProfile -ExecutionPolicy Bypass -File sim/eth_bridge/run.ps1 -Mode sim`：PASS，115/0。
- `powershell -NoProfile -ExecutionPolicy Bypass -File sim/d3/run_tx_rx.ps1`：TX/RX PASS。
- `powershell -NoProfile -ExecutionPolicy Bypass -File sim/d3/run_control_tb.ps1`：PASS，48/0。
- `powershell -NoProfile -ExecutionPolicy Bypass -File sim/d3/run_system_tb.ps1`：FAIL，PASS=238、FAIL=4；S4/S5 點比對問題經兩輪修正仍未解。
- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/d3/run_build_d3.ps1`：最終 PASS，工程模式全晶片綜合 0 errors，實現未執行。
- `git diff --check`：PASS。

工程模式建置為解決隔離 BD/IP 與 CDC 查詢問題曾多次執行；前次錯誤和對應證據保留在 `build_d3_attempt1.log` 至 `build_d3_attempt5.log`。最後一次 `build_d3.log` 為 PASS，綜合報告及其餘檢查由該次完成結果產生。

## 未完成與需協調

- 固定驗收項 3 的 S4/S5 回環波形逐點比較仍失敗。已按規定完成兩輪 TB 修正並停止該項，請 Claude 依 `system_tb/system_xsim.log` 的 `CAPTURE_SAMPLE`、`CAPTURE_COMPARE` 證據判定問題位於 TX/RX 模型對齊或資料路徑。未修改 `awg_tx`、`awg_rx`、`awg_control_v2`。
- GTYE4_CHANNEL 資源報告顯示總數 8，與文件 §6 的器件 GTY 16 不一致，請核對報告統計範圍。
- 未執行實現、bitstream、XSA、硬體、hw_server、JTAG 或 `192.168.42.x` 網路操作。
- `report_clock_interaction` 顯示多時鐘路徑需例外定義；現有 top timing XDC 在 Vivado XDC 解析中有 clock 覆寫與 Tcl `if` 不支援警告。本任務未新增或放寬例外，需另行審查約束歸屬。

## Claude 審查判定（2026-11-11）

已用實際日誌核對：bridge `PASS=115 FAIL=0`（S10 59.3 MB/s）、TX 26/26、RX 543552 點 0 錯、control 48/48、系統 TB `PASS=238 FAIL=4`；`payload_mem` 綜合為 2 塊 RAMB36E2；CDC 命中 10 項皆 > 0；synth_1 0 error。D3A4 bridge、頂層、綜合流程接受。

**S4/S5 失敗是 TB 回環模型錯，不是 RTL。** `tb_d3_system.sv` 的 loop_mem：DAC 側每個 dac_clk 寫 16 點（9.8 GS/s），ADC 側每個 adc_clk 讀 12 點（5 GS/s），寫指標每秒多前進 4.8 G 點，65536 點環形緩衝約 13.6 µs 就被追尾覆寫，讀出的是不連續片段（S5 實際 `04a0` vs 期望 `0230` 即跳段）。`loop_count` 飽和但寫指標仍前進，也掩蓋了溢位。另外 TB 波形（字 = base+k、高半字固定）每 4 個字的低半字截 14 bit 後相同，高半字全同，偏移搜尋本身有歧義；以 49/25 步距取樣時幾乎只取到高半字。→ D3A5 改模型與波形。

**時序約束未生效（D3B 前必修）：**
- `timing.xdc` 第 6–7 行 `get_clocks -quiet *a* *b*` 多個位置參數錯誤（須為 `{...}` 清單），第 9、12 行 `if` 在 XDC 不支援 → 兩組 `set_clock_groups` 都沒套上（CRITICAL WARNING 17-165、20-1307）。
- `create_clock pl_clk_p` 與 `qsfp2_refclk` 和 BD/IP 既有時鐘重複（18-619 覆寫、18-1056 完全覆蓋）。
- 結果：`report_clock_interaction` 中 `tx_clk→clk_pl_0` 190 端點、`clk_pl_0→tx_clk` 33 端點為 unsafe 且時序違例（TNS −165.6 / −28.9 ns）；MAC 內 `rxoutclk→txoutclk` 330 條 unsafe。
- `report_cdc`：`awg_tx` 的 `crc_busy` 由 FSM 狀態組合邏輯直接進同步器（CDC-10 Critical）→ 必須先在 tx_clk 域打一拍。

GTYE4_CHANNEL 可用 8：xczu47dr-fsve1156 封裝只引出 8 個 GTY，非錯誤；`doc/00` §6 的 16 是晶片總數，之後更正文件。
