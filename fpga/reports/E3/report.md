# E3_HOST 執行報告

**結果：PASS**。固定驗收 4 項全部完成；所有 UDP 測試僅使用 `127.0.0.1`，未向 `192.168.42.x` 發送封包，也未操作硬體、JTAG 或 `hw_server`。

## 完成項目

- 新增 `tools/awg_eth/`：凍結協定 codec、UDP client、v2 AWG API、CLI、GUI 檔案 IPC 橋接、loopback FPGA emulator，以及 13 個 pytest。
- MATLAB `AWGBridge` 依 `cfg.transport` 選擇既有 JTAG 或 Python Ethernet backend；預設仍為 JTAG。`AWGScopeApp` 增加傳輸/IP/UDP 埠設定、v2 波形匯出及 v2 CSV/JSON 擷取載入。
- MATLAB 測試輸出和執行日誌寫入本目錄；增加 MATLAB 到 emulator 的 Ethernet 端到端驗收。

## 驗收結果

1. **pytest：PASS，13 passed，0 failed。** 覆蓋封包編解碼、區塊讀寫、狀態錯誤、CRC、擷取格式、GUI IPC，以及 8 通道 × 131072 點的 load+CRC verify。最大波形測試使用 10% 回覆丟失與 10% 重複封包注入；所有通道字數和 CRC 均正確。
2. **Loopback bench：PASS，無丟包。** 寫入 131040 bytes，測得 **5.491 MB/s**；讀取 131040 bytes，測得 **2.417 MB/s**。結果見 `bench.log`。
3. **MATLAB：PASS，退出碼 0。** `test_awg_matlab`、`test_awg_app` 與新增 Ethernet E2E 均通過；記錄見 `matlab_acceptance.log`。Vivado 測試環境設定為 `PROCESSOR_ARCHITECTURE=AMD64` 並清除 `NoDefaultCurrentDirectoryInExePath`；JTAG 回歸僅使用 mock Tcl，Ethernet E2E 僅連 `127.0.0.1`。
4. **網路限制：PASS。** 客戶端測試、CLI bench、MATLAB Ethernet E2E 均指定 `127.0.0.1`；未對 `192.168.42.x` 發包。

## 執行命令

- `py -X utf8 -m compileall -q tools/awg_eth`：PASS。
- `py -X utf8 -m pip install pytest`：PASS；pytest 原先未安裝，僅安裝到目前 Python 3.12 環境，未新增專案依賴。
- 設定 `PYTHONPATH=<工程根目錄>/tools` 後執行 `py -X utf8 -m pytest -q tools/awg_eth/tests`：13 passed，4.77 s。
- 從 `tools/` 執行 `py -X utf8 -m awg_eth.cli --help`：PASS；CLI 子命令包含 `ping/info/status/load/start/stop/capture/bench`。
- emulator：`py -X utf8 -m awg_eth.fpga_emu --host 127.0.0.1 --port 19100 --loopback`；CLI：`py -X utf8 -m awg_eth.cli --ip 127.0.0.1 --port 19100 bench`：PASS，數值如上。
- 設定 Vivado 必要環境變數後執行 `matlab.exe -batch "cd('<工程根目錄>/matlab'); test_awg_matlab; test_awg_app"`：PASS，退出碼 0。

## 未測與協調事項

- `sim/tx/crc_ref.py` 尚不存在；依任務要求新增獨立測試參考 `tools/awg_eth/tests/crc_ref.py`，並以相同 IEEE CRC-32 位元組規則比對。D1 參考檔存在後可再交叉核對。
- checkout 缺少 `hardware/dac9g_opt1/rf_awg_init.elf`。MATLAB app 測試將此套件存在性檢查標示為 `UNTESTED`；E3 固定驗收不依賴該初始化 ELF，未執行初始化或硬體測試。
- 早期 MATLAB 測試輸出曾改寫非歸屬檔案 `sim/matlab_fixtures/capture.mat`，並在 `app_data/waveforms/` 留下測試波形。兩者都未清理；依任務檔案歸屬限制保留現狀。測試程式已改為把後續產物寫到 `reports/E3/`，最終驗收未再寫入這些位置。
- 無需修改凍結規格；E3 檔案歸屬已完成。沒有待執行工作。

## 主要檔案

- `tools/awg_eth/__init__.py`
- `tools/awg_eth/protocol.py`
- `tools/awg_eth/client.py`
- `tools/awg_eth/awg.py`
- `tools/awg_eth/cli.py`
- `tools/awg_eth/gui_bridge.py`
- `tools/awg_eth/fpga_emu.py`
- `tools/awg_eth/tests/`
- `matlab/AWGBridge.m`
- `matlab/AWGScopeApp.m`
- `matlab/test_awg_app.m`
- `matlab/test_awg_matlab.m`
- `reports/E3/status.json` 與本報告
