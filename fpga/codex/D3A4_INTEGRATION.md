# D3A4_INTEGRATION — 整合第四輪：bridge 修正、系統模擬補齊、工程模式全晶片綜合

先讀 `AGENTS.md`、`doc/00_ETH_PLAN.md` §4、`doc/01_DATAPATH_V2.md`、`reports/D3A3_INTEGRATION/report.md`（**最後的「Claude 審查判定」節**）。

## 目前狀態（Claude 已驗證，commit 3918bf4）

- 控制器、awg_rx abort、真實 BD 頂層（reset 同步、SYSREF 兩級、up_ 匯流排）已審查接受。
- Claude 修了系統 TB 的三個錯（status 位移、tkeep、TB FIFO 深度），重跑 `sim/d3/run_system_tb.ps1`：`PASS=165 FAIL=1`。唯一失敗是 S7 讀取 31.4 MB/s；寫入 45.8 MB/s。
- **不要重寫已通過的部分。** 本任務只做下面列出的項目。

## 要做的

### 1. `rtl/eth/awg_eth_bridge.sv`

1. **改回同步讀**：`payload_mem` 是 `ram_style="block"`，D3A3 加的 `payload_mem[exec_index>>1]`、`payload_mem[next_exec_index>>1]` 是非同步讀，不能推成 BRAM。只准一個同步讀口（`payload_rd_data <= payload_mem[addr]`），以預取維持吞吐：當前字的 AW/W 送出時就發下一個 qword 的讀位址（每個 qword 內含兩個 32 bit 字，exec_index 偶數時才需要讀新 qword）。
2. **讀路徑**：照寫路徑做法，R 回來且還有下一字時，直接發下一個 AR，不回 ST_EXEC。
3. **TX FIFO 容量**：TX FIFO 是 128 bit 寬、每格放一個 64 bit 酬載、`DEPTH` 以位元組計。最大回覆（`MAX_WORDS` 字讀取）需要 `1 + ceil((24 + 4*MAX_WORDS)/8)` 格。加 elaboration 期檢查（`generate if` 中 `$error` 或同等寫法）：`TX_FIFO_DEPTH/16` 小於所需格數就報錯；`RX_FIFO_DEPTH` 同樣檢查最大寫請求。
4. 重跑 `sim/eth_bridge` 全部情境 S1–S11。把 S10 的門檻從 80 改成 40 MB/s（80 是目標，報告數字即可）；其他判據不准改。

### 2. 正式頂層

- bridge `TX_FIFO_DEPTH` 改 32768（`MAX_WORDS=2048` 需 1028 格，16384 只有 1024 格）。core 的 FIFO 參數照 bridge 同樣規則核對，不夠就改並在報告列出計算。

### 3. 系統 TB `sim/d3/tb_d3_system.sv`（在 Claude 修好的版本上**增加**，不要改既有的 udp_send/udp_receive）

1. S2：兩個通道的 CRC 都要斷言，期望值 ch0 `9014BEF6`、ch1 `65FFA182`（Claude 已用 Python 按 `sim/tx/crc_ref.py` 規則算過；TB 寫入字為 `base + k`，`[15:0]` 先）。讀 CRC 前輪詢 STATUS bit8 為 0。每個通道寫完後讀 `TX_WR_PTR` = 4096。
2. S4（trig_mode=1）：擷取長度至少 64 字（1536 點），讀回 ch0、ch1 全部，與 TX 波形（14 bit，低 2 bit 為 0，循環長度 = TX_LENGTH×32）找一個固定偏移，逐點全等；報告偏移。`CAP_TX_WORD` 與起播位置誤差 ≤ 24 字。
3. S5（trig_mode=0）：同樣比對（回環資料是 TX 循環波形的連續片段）。
4. 新增 S8 abort：trig_mode=1 arm 後不 start → 讀 CAP_STATUS armed=1 → COMMAND=32 → armed=0、busy=0 → 再 arm 成功。busy 時讀 CAP_RD_DATA 回 status=1（AXI_ERR），不得逾時。
5. 新增 S9 背壓：在 control 與 awg_tx 之間插入 TB 控制的 ready 遮罩（隨機拉低），寫一個通道 4096 點，CRC 正確且 `TX_WR_PTR` = 4096。
6. S7：寫、讀各 64 KiB，讀的是有效擷取資料（擷取長度足夠或在擷取範圍內重複讀），每個回覆 status=0。驗收：寫 ≥ 40 MB/s、讀 ≥ 30 MB/s（硬門檻）；目標兩者 80。報告每字週期分解（bridge / arb / control / awg_rx 或 awg_tx），用 TB 計數器量。
7. 最後印 `RESULT name=tb_d3_system PASS=.. FAIL=..`。

### 4. 建置：改用 D0 的工程模式流程（`scripts/d3/build_d3.tcl`）

D3A3 用手動加入 generated 檔案的方式跑 `synth_design -rtl`，被 BD/IP 的 library 依賴卡住。不要再走這條路。改成照 `scripts/d0/build_d0.tcl`：

1. `create_system_v2.tcl` 在 `build/D3A4_INTEGRATION/` 建工程與 BD（它會把 BD diff 寫在參數 dump 旁邊，複製到 `reports/D3A4_INTEGRATION/`；不准寫到其他任務的報告目錄）。
2. `open_project`，加入頂層與所有 v2 RTL、`jtag_axi` IP（`create_ip` 照 `scripts/build.tcl` 第 58–59 行）、E2 光口 IP（`build/E2/ip_staging/*.xci`，`import_ip`）、`constraints/top/*.xdc`；`cdc.tcl` 設為 synth 之後、`opt_design` 之前載入（`STEPS.OPT_DESIGN.TCL.PRE` 或同等方式）。
3. **本任務跑完整綜合**：`launch_runs synth_1 -jobs 2`、`wait_on_run`，0 error。之後 `open_run synth_1`，在綜合後網表上 `source cdc.tcl`，每條約束命中數 > 0（貼出數字）。
4. 綜合後報告：`report_utilization`（URAM、RAMB36/18、LUT、FF、GT）、`report_ram_utilization`（確認 bridge `payload_mem`、TX URAM OREG、RX BRAM 都是 block）、`report_clocks`、`report_clock_interaction`、`check_timing`、`report_cdc -details`。
5. **不跑實現、不產生 bitstream**。腳本的實現段落寫好，用參數關閉。
6. 開頭 `set_param general.maxThreads 20`；同時最多 3 個 Vivado 行程。

## 歸屬檔案

- `rtl/eth/awg_eth_bridge.sv`、`sim/eth_bridge/**`
- `rtl/top/**`、`sim/d3/**`、`scripts/d3/**`、`constraints/top/**`
- `build/D3A4_INTEGRATION/**`、`reports/D3A4_INTEGRATION/**`
- 其他全部唯讀。若證明 awg_tx/awg_rx/awg_control_v2 有錯，停該項、報告證據，不要改。
- 不准在工程根目錄留下 Vivado 輸出檔（`clockInfo.txt` 之類）。

## 驗收（固定）

1. `sim/eth_bridge` S1–S11 全 PASS（S10 ≥ 40 MB/s），貼計數與 S10 數字。
2. `sim/d3/run_tx_rx.ps1`、`run_control_tb.ps1` 仍全 PASS（貼計數）。
3. 系統 TB S1–S9 全 PASS，有 `RESULT` 行；S4/S5 逐點比對 0 錯；S7 寫 ≥ 40、讀 ≥ 30 MB/s，附週期分解。
4. 全晶片 `synth_1` 完成 0 error；`payload_mem` 為 block RAM；`cdc.tcl` 在綜合網表上每條命中 > 0；BD diff `unexpected=0`。
5. 資源表（綜合後實數）對照 `doc/00` §7：URAM、RAMB36 等效、GT。
6. 某一項同一失敗修 2 輪仍失敗：只停該項，其他繼續；status 寫 `NEEDS_PARENT_JUDGMENT` 並列出卡住項與證據。
7. 不做任何硬體操作。
