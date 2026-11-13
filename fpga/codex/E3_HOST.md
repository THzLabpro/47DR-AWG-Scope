# E3_HOST — Python 主機端 + FPGA 協定模擬器 + MATLAB 傳輸切換

先讀 `AGENTS.md`、`doc/00_ETH_PLAN.md`（§3、§4 凍結）、`doc/01_DATAPATH_V2.md`（§5、§6 凍結：v2 暫存器表與主機流程）。

## 背景

v1 主機流程：MATLAB `AWGScopeApp` → `AWGBridge`（啟動 Vivado batch，跑 `scripts/awg_gui_bridge.tcl`，用 session 目錄裡的 `.req/.res/progress.txt/heartbeat` 檔案通訊）→ `scripts/awg_hw.tcl`（JTAG 讀寫）。
新流程：同一套檔案 IPC，但後端換成 Python，經 UDP 9100 與 FPGA 通訊。初始化（`scripts/program.tcl`，JTAG）不變。

## 歸屬檔案（只能寫這些）

- `tools/awg_eth/**`（Python 套件、CLI、GUI 橋接、模擬器、pytest 測試）
- `matlab/AWGBridge.m`、`matlab/AWGScopeApp.m`、`matlab/test_awg_app.m`、`matlab/test_awg_matlab.m`（只做傳輸切換所需的最小修改）
- `reports/E3/**`

## 要做的

1. `tools/awg_eth/protocol.py`：plan §4.2 封包編解碼（純函式，有單元測試）。
2. `tools/awg_eth/client.py`：`AwgEthClient(fpga_ip, port=9100, local_ip=None, words_per_packet=256, window=8, timeout=0.05, retries=5)`
   - `read32/write32`、`read_block/write_block`（大塊自動分包、視窗化在途、逾時重傳同一 seq）、`ping`、`info`。
   - 控制暫存器寫（`0x90200008/0C/10`）強制 window=1。
   - 錯誤以例外回報（含 status、err_index、地址）。
   - socket 收發緩衝設大（≥ 8 MB），不用忙等迴圈燒 CPU。
3. `tools/awg_eth/awg.py`：對外 API 與 `scripts/awg_hw.tcl` 相同（status、command、stop、clear、start、load(directory, verify)、wait_capture_done、capture(csv_path, trigger, channel_mask)），進度回呼介面同 Tcl；
   **但硬體操作改用 v2 暫存器表和流程（`doc/01_DATAPATH_V2.md` §5、§6）**：ABI `0x00030001`、DAC 9.8 GS/s（meta `fs_hz` = 9800000000）、ADC 5 GS/s、
   波形 32..131072 點且 32 的倍數、擷取 24..65520 點且 24 的倍數、TX_WR_DATA/CAP_RD_DATA 用 NOINC 連續傳、load 的 verify 用 CRC-32（規則見 §3）而非逐字讀回、
   trigger `manual` / `start`（start = CAP_CTRL.trig_mode=1，arm 後再 start）。
   meta 檔格式沿用 v1（`samples fs_hz nco_hz channel_mask sample_format`）；樣點 int16，低 2 bit 會被硬體丟棄，主機在 CRC 計算前先清零低 2 bit。
   CSV/JSON 輸出格式沿用 v1，JSON 的 `format` 改為 `47dr-raw-adc-v2`、`sample_bits` 改為 14、加 `cap_tx_word`。
4. `tools/awg_eth/gui_bridge.py`：與 `scripts/awg_gui_bridge.tcl` 相同的 session 檔案協定（config.txt、hello.res、`*.req` → `*.res`、progress.txt、heartbeat 逾時 120 s 退出、dispatch 動作相同）。
   config.txt 新增 `fpga_ip`、`port`、`words_per_packet` 欄位；connect 時做 ping + info，hello.res 帶回 INFO 內容。
5. `tools/awg_eth/cli.py`：`py -X utf8 -m awg_eth.cli --ip 192.168.42.2 {ping,info,status,load DIR,start,stop,capture CSV --mask N,bench}`；
   `bench` 量測寫/讀 MB/s。
6. `tools/awg_eth/fpga_emu.py`：在 127.0.0.1 上跑的 FPGA 模擬器，完整模擬 plan §4.2（含去重、BAD_REQ、丟包注入參數）以及 **`doc/01_DATAPATH_V2.md` §5 的 v2 暫存器語意**
   （資料埠、14 bit 截斷、CRC、執行中 SLVERR、start 檢查、擷取狀態與讀指標；擷取資料用可預測樣點，可選擇把 TX 波形經固定延遲「回環」成 ADC 資料，方便端到端測試）。
7. pytest（`tools/awg_eth/tests/`）：協定編解碼、client 對模擬器的讀寫比對（含 10% 隨機丟包和重複包注入）、load+verify 全 8 通道 131072 點、CRC 與 `sim/tx/crc_ref.py`（D1 產出，若尚不存在則自寫並在報告註明）規則一致、capture 輸出格式、gui_bridge 的檔案協定端到端。
8. MATLAB：`AWGBridge.start` 依 `cfg.transport`（`'jtag'` 預設維持原行為；`'eth'` 啟動 `py -X utf8 tools/awg_eth/gui_bridge.py <session>`）。
   `AWGScopeApp` 加一個最小的傳輸選擇（下拉或設定欄位，含 FPGA IP），其他 UI 不動。既有 MATLAB 測試必須仍然 PASS，並加一個 `transport='eth'` 對 `fpga_emu` 的端到端測試。

## 驗收（固定）

1. pytest 全 PASS（貼出計數）。
2. 對模擬器（無丟包）`bench`：報告寫/讀 MB/s；10% 丟包下 load+verify 8 通道仍正確。
3. MATLAB 既有測試 + 新的 eth 測試全 PASS（`matlab -batch` 日誌在 `reports/E3/`）。
4. 不得發任何封包到 192.168.42.x。
