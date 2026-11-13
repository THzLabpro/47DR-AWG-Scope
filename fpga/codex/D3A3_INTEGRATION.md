# D3A3_INTEGRATION — 整合第三輪：修控制器、換回真實 BD/IP 頂層、補齊系統模擬

先讀 `AGENTS.md`、`doc/00_ETH_PLAN.md`（§4 status 碼）、`doc/01_DATAPATH_V2.md`（全部凍結；2026-11-11 D3A2 審查後新增：COMMAND=32 abort capture、`h_abort`/`h_armed`、STATUS bit1 定義、CAP_RD_DATA busy 時 SLVERR）、`codex/D3A_INTEGRATION.md`（原驗收）、`reports/D3A2_INTEGRATION/report.md`。
參考：`rtl/d0/d0_probe_top.v` 與 `scripts/d0/build_d0.tcl`、`scripts/d0/build_d0r2.tcl`（全晶片時序已收斂的寫法）、v1 `rtl/adaloop_top.v`（up_ 匯流排與 user_control 接法）、`build/E2/ooc_synth.tcl`（光口 IP 匯入）。

本任務仍**只到 `synth_design -rtl`**，不跑綜合/實現/bitstream。

## Claude 審查 D3A2 的判定（必須全部處理）

### A. awg_control_v2 的 RTL 錯誤

1. **TX_WR_DATA 握手錯誤**：`ST_WR_DATA` 在同一拍設 `tx_h_wr_valid<=1` 又檢查 `tx_h_wr_ready`。valid 晚一拍才出現，所以 ready 掉下時會丟字；而 valid 已高、ready 才拉高的那拍，下一拍 valid 又被設成 1，會重複寫一次。改成標準 valid/ready：valid 保持到 `valid && ready` 那拍才放下，B 回應在該拍之後。
2. **STATUS 位元順序錯**：現在是 bit1 locked、bit4:3 result、bit5 fault、bit6 crc_busy、bit7 cap_busy、bit8 cap_done。要照 `doc/01` §5：bit0 running、bit1 cmd_busy、bit2 ps_ready、bit3 fault、bit5:4 last_cmd_result、bit6 cap_busy、bit7 cap_done、bit8 crc_busy。E3 主機輪詢 bit8 等 CRC，現在讀到的是 cap_done。
3. **CAP_RD_DATA 死鎖**：rx busy 時進 `ST_RD_DATA` 卻不發請求，永遠不回 R。改成 busy 時立即 SLVERR。D3A2 系統模擬 S7 讀取逾時就是這個原因。
4. **無法取消擷取**：trig_mode=1 arm 後如果沒有 start，CAP_CTRL、arm 全部 SLVERR，只能 reset。加 COMMAND=32 abort；awg_rx 加 `h_abort` 輸入與 `h_armed` 輸出（host→rx 用 toggle 同步，照 awg_rx 現有 arm 的寫法）。CAP_STATUS bit2 = armed（不能再用 busy 代替）。
5. **範圍檢查只看低位元**：TX_LENGTH 只看 `wdata[12:0]`，`0x0001_0001` 會被當成 1 接受；TX_WR_CH、CAP_CTRL、CAP_RD_PTR 也一樣。改成檢查完整 32 bit，保留位非 0 一律 SLVERR。
6. 刪掉 `start_counts_ok` 裡無意義的 `(selected_wr_ch == selected_wr_ch)`。

### B. 正式頂層退化（`rtl/top/awg_eth_top.v`）

1. **不准用同名 stub 取代真實 IP/BD**：刪掉 `rtl/top/system_blackbox.v`、`jtag_axi_stub.v`、`eth_ip_stubs.v`。`synth_design -rtl` 要在真實的 BD wrapper（`create_system_v2.tcl` 產生、`generate_target`）、真實 `jtag_axi` IP、E2 的 `optical_port2`/`demo_management_clock` IP 上通過。模擬需要的行為模型放在 `sim/d3/`，模組名不得與真實 IP 相同，也不得加入建置。
2. **reset 結構要照 D0R2**：每個域（dac、tx、adc、rx、host）都用 `d0_reset_sync`（或同等寫法）加 `MAX_FANOUT` 本地 reset 暫存器；awg_tx/awg_rx/control/bridge/user_control 只接同步後的 reset。D3A2 把 BD 的 `rf_resetn`、`adc_axis_resetn` 直接接進 612.5/416.667 MHz 域，這正是 D0 第一輪時序失敗的原因之一。
3. **SYSREF 照 D0R2 兩級**（`pl_sysref_r` → `*_meta` → `user_sysref_*`），不是一級。
4. **up_ 匯流排沒接**：`up_wack`、`up_rdata`、`up_rack` 被綁成常數，user_control 的輸出懸空。PS 韌體寫 config_done 時收不到 ack，`ps_ready` 永遠為 0，start 永遠被拒。照 v1 `adaloop_top.v` 把 user_control 的 up_wack/up_rdata/up_rack 接回 BD；`adc_freeze`/`adc_clear_ov` 照 v1 接法，v2 不需要的在報告說明。
5. 先確認 BD 的 up_ 埠方向（`create_system_v2.tcl`），頂層 wire 方向要一致。

### C. 約束

1. `board.xdc` 要包含 D0 板級約束（`constraints/d0/d0_board.xdc`：RFDC、時鐘、LED 腳位）與 `constraints/eth/awg_eth_core.xdc`（QSFP2）。DRC 在 elaborated design 上不得有缺 LOC/IOSTANDARD 的 critical warning。
2. `timing.xdc` 補齊 D3B 需要的時鐘關係：host（`clk_pl_0`）↔ RF 時鐘、`clk_eth` ↔ host 的 `set_clock_groups -asynchronous`，前提照 D3A §4（報告列出全部跨域點與保護方式）。dac↔tx、adc↔rx 不准有例外。clock 名稱要用 elaborated design 實際查到的，並在報告貼出 `get_clocks` 結果。
3. `cdc.tcl`：命中 0 的約束要 `error`，不准默默跳過。`gray` 那條指向不存在的 `write_words_gray_*`（awg_tx 已改 xpm）：刪掉，不要保留 0 命中的條件分支。
4. RFDC IP 內部 CDC 的 `create_waiver` 寫進 `cdc.tcl`（或另一個 Tcl），D3B 用；本任務只要語法能載入。

### D. 系統模擬 `sim/d3/tb_d3_system.sv`

1. **時鐘比例錯**：TB 的 `tx_clk` 與 `dac_clk` 同頻（都是 1.632 ns 半週期）。要由 TB 從 `dac_clk` 二分頻產生 `tx_clk`，同相；`rx_clk` 也從 `adc_clk` 二分頻產生。
2. **沒有 DAC→ADC 回環**：D3A §5 要求回環。用以下模型（報告寫明）：把 8 個通道的 `dac_tdata`（16 樣點/拍）推進每通道一個樣點佇列，ADC 側每拍取 12 個樣點輸出；模擬時 ADC 時鐘取 `f_dac×16/12`（約 816.67 MHz），讓兩邊樣點率相等，`rx_clk` 仍是 ADC 時鐘的一半。DAC 送 0（停止）時佇列也照常推 0。
3. **status 碼錯**：SLVERR 回到主機是 `status=1`（AXI_ERR，見 `doc/00` §4），TB 卻比對 2，所以 S3 的兩個 SLVERR 檢查才「失敗」。用具名常數。
4. **S2 CRC 讀回 0 未判失敗**：要比對期望 CRC（TB 內用與 `sim/tx/crc_ref.py` 相同規則計算，或由 Python 預先產生），兩個通道都要比對（ch1 證明通道選擇有效）。讀 CRC 前輪詢 STATUS bit8 直到 0。若 CRC 仍為 0，先查 awg_tx CRC 是否被觸發（`h_locked`、clock 比例），不要放寬檢查。
5. **S4 要做資料比對**：trig_mode=1，arm → start → done 後，讀回兩個啟用通道全部擷取長度，對 TX 波形（14 bit，低 2 bit 為 0）找一個固定偏移，所有樣點逐一相等；報告偏移值。`CAP_TX_WORD` 在 `doc/01` 的 ≤ 24 字內。
6. **S5** trig_mode=0：完成並讀回正確（回環資料仍是 TX 波形的連續片段）。
7. **新增 S8 abort**：trig_mode=1 arm 後不 start → COMMAND=32 → CAP_STATUS armed=0、busy=0 → 能再次 arm。另測 busy 時讀 CAP_RD_DATA 回 status=1 而不是逾時。
8. **新增 S9 TX_WR_DATA 背壓**：在 awg_tx 前插入 TB 控制的隨機 ready 遮罩（或縮小 FIFO 參數）製造背壓，寫 4096 點後 CRC 必須正確、`TX_WR_PTR` 剛好 4096。
9. 情境之間互相獨立：每個情境開始先 stop + abort，回到已知狀態，前一個失敗不得連鎖造成後面失敗。
10. 最後必須印出 `RESULT name=tb_d3_system PASS=.. FAIL=..`；任何逾時都算 FAIL 並繼續下一個情境，不得中止整個 TB。
11. 控制器單元 TB（`tb_awg_control_v2.sv`）同步補：STATUS 每個位元、TX_WR_DATA 背壓（ready 隨機）不丟不重、CAP_RD_DATA busy SLVERR、abort、範圍檢查的保留位。

### E. 吞吐（S7）

D3A2 實測寫入 175835 個 host_clk 寫 16384 字，約 10.7 拍/字（37.3 MB/s）。目前 bridge 每字流程是 EXEC → PAYLOAD_WAIT → AW/W → 再一拍才設 `axi_b_wait` → 等 B；控制器每字也要 IDLE → WRITE → WR_DATA → B。

1. 先在報告列出每字花在 bridge、arb、control、awg_tx 背壓的週期數（用 TB 計數器量，不是估算）。
2. 控制器：AW 與 W 同拍到達時當拍接受，TX_WR_DATA 在 FIFO 有空間時下一拍回 B。
3. **本任務允許修改 `rtl/eth/awg_eth_bridge.sv` 的 AXI master 部分**（只限吞吐優化）：例如 AW/W 送出後立即等 B（不多一拍）、預取下一個 payload 字、NOINC 連續字之間不回到 EXEC。修改後重跑 `sim/eth_bridge` 全部情境 S1–S11，全 PASS（S10 吞吐數字一併報告）。
4. 驗收：S7 寫、讀各 ≥ 40 MB/s（硬門檻）；目標 80 MB/s（≤ 5 拍/字），達不到目標時附週期分解即可。

### F. 建置腳本 `scripts/d3/build_d3.tcl`

1. 從 `create_system_v2.tcl` 建 BD、`make_wrapper`、`generate_target`；`jtag_axi` 照 `scripts/build.tcl` 第 58–59 行建立；光口 IP 照 E2 的匯入方式。
2. `synth_design -rtl -top awg_eth_top` 0 error。
3. **BD 參數 diff 要在本任務真正重跑**（D3A2 是拿 D0 舊產物回填，而且改了 `reports/D0/bd_param_diff.txt`，Claude 已還原）。輸出只寫到 `reports/D3A3_INTEGRATION/`，不准改其他任務的報告目錄。若 Vivado 內呼叫 Python 有問題，就在 Vivado 外由 `run_build_d3.ps1` 執行比對。
4. `cdc.tcl` 在 elaborated design 上載入，每條命中數 > 0；報告貼出命中數。
5. 建置腳本後半段（綜合、實現、報告、bitstream、XSA）照 D3A §6 寫好，但本任務用參數控制只跑到 elaboration。

## 歸屬檔案

- `rtl/top/**`、`rtl/ctrl/**`、`constraints/top/**`、`scripts/d3/**`、`sim/d3/**`
- `rtl/rx/awg_rx.sv` + `sim/rx/**`：只為 `h_abort`/`h_armed`；重跑 R1–R4，加一個 abort 情境。
- `rtl/eth/awg_eth_bridge.sv` + `sim/eth_bridge/**`：只限 E 節的吞吐優化；重跑 S1–S11。
- `rtl/tx/**` 唯讀（若 S2/S9 證明 awg_tx 有錯，停下報告，不要自己改）。
- `build/D3A3_INTEGRATION/**`、`reports/D3A3_INTEGRATION/**`。xsim 與 Vivado 只在 `build/D3A3_INTEGRATION/` 下跑；不准在工程根目錄留下 `clockInfo.txt` 之類的 Vivado 輸出。

## 驗收（固定）

1. sim/tx T1–T6（26 PASS，CRC `D49307A0`）、sim/rx R1–R4 + abort、sim/eth_bridge S1–S11 全 PASS，貼計數。
2. awg_control_v2 單元 TB 全 PASS，包含 A 節每一項的檢查。
3. 系統模擬 S1–S9 全 PASS，有 `RESULT` 行；S4/S5 逐點比對 0 錯；S7 寫、讀各 ≥ 40 MB/s，附每字週期分解。
4. 真實 BD/IP 上 `synth_design -rtl` 0 error；DRC 無缺腳位約束的 critical；BD diff 在本任務重跑 `unexpected=0`；`cdc.tcl` 每條命中 > 0。
5. 報告列出所有跨時鐘域點（來源域、目的域、保護方式），作為 `set_clock_groups` 的依據。
6. 某一項同一失敗修 2 輪仍失敗：只停該項並標記，其他不依賴它的項目繼續做；最後 status 寫 `NEEDS_PARENT_JUDGMENT` 並列出卡住的項目與證據。
7. 不做任何硬體操作。
