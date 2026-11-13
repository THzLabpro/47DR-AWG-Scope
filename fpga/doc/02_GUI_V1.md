# 上位機 GUI V1（2026-11-12）

## 目的

讓這台 47DR AWG/示波器可以像桌上型儀器一樣操作：
- 前半像函數產生器 / AWG：產生標準波形或匯入波形檔，下載後循環播放；
- 後半像示波器 / 頻譜儀：擷取 ADC，顯示時域、頻譜與量測。

腳本 API（類似 M8195A 驅動的函式介面）之後再做。GUI 之後也會再改，V1 先求能用、好改。

## 使用者已決定

- **獨立 Python GUI**，不依賴 MATLAB。
- 介面概念參考 R&S / Keysight 儀器：
  - M8195A 軟體面板的分頁式 AWG 設定；
  - RTO6 / Infiniium 的「大波形區 + 側邊設定 + 量測卡」；
  - Infiniium 的 FFT 像頻譜儀一樣操作。
- **幅度 V1 先用數位比例（dBFS）**。dBm / Vpp 校準與 DAC VOP 類比調整之後再做。
- 吞吐分三版：
  - V1：只改主機端，逼近現架構上限；
  - V2：10–20 Gb/s，FPGA 直寫通道；
  - V3：接近 40 Gb/s。

## 範圍（V1 GUI）

1. **連線列**：IP / 埠、連線狀態（PING、ps_ready、ABI、BUILD_ID）、DAC 9.8 / ADC 5 GS/s 顯示。
   - 「輸出 Run/Stop」控制 AWG 播放；
   - 「擷取 Single / Run」控制單次或連續擷取。
2. **AWG 區（左側分頁）**：
   - **標準波形**：每通道可選函數，包括正弦、方波、三角、鋸齒、脈衝、雜訊、多音、chirp、DC。
     - 可設頻率、幅度（dBFS）、相位、直流偏移、方波/脈衝的占空比、長度（32 的倍數，最多 131072）。
     - 頻率自動對齊到循環長度的整數週期（顯示實際頻率），確保無縫循環。
   - **匯入**：讀 `.npy`、`.csv`、`.txt`、`.mat`、v1 的 hex 目錄格式，指定到通道。
     - 超過 ±1 時可選正規化或截斷；長度要補齊或截斷到 32 的倍數。
   - **輸出**：8 通道開關（TX_MASK）與每通道幅度縮放。
     - 「下載到 AWG」會走 CRC 驗證，並顯示進度與耗時。
3. **示波器區（右側）**：
   - **時域圖**：多通道疊圖，各通道可開關顯示，可縮放平移，縱軸 LSB 或 FS。
   - **頻譜圖**：dBFS，可選窗函數；用中心 / 跨度設定顯示範圍，RBW = Fs/N × 窗係數。
     - 有峰值標記 M1，以及 M2 與 M1 的差值標記。
   - **擷取設定**：觸發選手動或起播同步，長度 24 的倍數、最多 65520，通道遮罩。
   - **量測卡**：選定通道的頻率、Vpp、RMS、SFDR、SINAD/SNR。
   - **存檔**：CSV + JSON，沿用現有 `47dr-raw-adc-v2` 格式。
4. **狀態列 / 記錄**：最近一次操作結果、錯誤訊息、FAULTS、擷取計數，以及溫度（目前無法經光口取得，不顯示）。

## 不做（V1）

- 腳本 API、MATLAB 介面。
- 插值、NCO、調變波形（AM/FM）、序列 / 分段播放。
- dBm 校準、DAC VOP 調整（需要 PS 韌體指令通道）。
- 開機初始化：仍用 `scripts/program.tcl`。GUI 只連已初始化好的板子。

## 反目標

- GUI 卡住或凍結：所有網路操作都放在背景執行緒，下載與擷取可以取消。
- 下載後不驗證就說成功：每個通道都必須 CRC 吻合。
- 波形接縫跳變：標準波形一律整數週期。

## 限制

- 只能透過光口和 `tools/awg_eth`，不碰 JTAG；不修改 FPGA。
- D3C 位元流：每包 2048 字，資料埠是停等式；吞吐約 11 MB/s，V1 吞吐優化後會更快。
- Windows 10、Python 3.12。現有 PySide6、numpy；需要再裝 pyqtgraph（繪圖）和 scipy（讀 `.mat`）。

## Claude 的決定（可推翻）

- PySide6 + pyqtgraph；程式放 `tools/awg_gui/`，入口 `py -X utf8 -m awg_gui`。
- 波形產生與量測演算法放在純 numpy 模組，有單元測試；GUI 只負責呈現。
- 可用 `tools/awg_eth/fpga_emu.py` 在 127.0.0.1 離線測試。
- 介面文字用**簡體中文**（使用者 2026-11-12 要求），數值單位用工程記號（MHz、dBFS）。
- 設定存到 `%APPDATA%/awg_gui/settings.ini`（QSettings），記住 IP、埠、每包字數、最近目錄與視窗位置。
- 流暢度：
  - 網路操作和 FFT/量測都在 `DeviceWorker` 執行緒裡做；
  - 繪圖使用 pyqtgraph 的峰值降採樣加 clipToView；
  - 進度回報每秒最多 20 次；
  - 連續擷取透過事件迴圈排程，隨時可以停止。

## 執行方式

```
cd tools
py -X utf8 -m awg_gui               # 連板卡（先用 program.tcl 初始化）
py -X utf8 -m awg_gui --emulator    # 離線：本機回環模擬器
py -X utf8 -m pytest -q awg_gui/tests
```

## 驗收

1. 單元測試：
   - 波形產生：頻率對齊、長度、幅度上限、14 bit 量化；
   - 量測：已知正弦的頻率、SFDR、SINAD；
   - 檔案匯入。
2. 對模擬器跑完整流程：連線 → 產生 8 通道 → 下載含 CRC → Run → 擷取 → 顯示 → 存檔。
3. 上板時要先經使用者同意：CH0 回環能看到設定的單音，量測頻率與設定一致。

## 2026-11-12 試用後修正（E6）

- **時域圖空白**：clipToView 加降採樣時，初始顯示範圍 0–1 s 對 13 µs 的資料什麼都畫不出來，自動範圍也就不會動。
  - 現在每次擷取後明確設定範圍，預設顯示約 10 個週期（類似示波器 Auto）；
  - 新增「时域自动」「全长」兩個按鈕。
- **下載不放在分頁裡**：改成左側固定的「下载 / 输出」區。
  - 預設勾選「生成/导入后自动下载」和「下载后自动 Run」；
  - 已在播放時再按 Run 不再報錯。
- **速度（主機端）**：資料埠改成管線化。
  - 寫入：每包 512 字、在途 12 KB。上限來自板上實測：橋接器 RX FIFO 約只容得下 16 KB 寫入資料。
  - 讀取：每包 2048 字、同時 6 包。
  - 管線傳輸時執行緒固定在單一 CPU。板上實測：Windows 執行緒換核心會讓相鄰封包對調，26/80 次寫錯；固定後 0/80。
  - 逾時不重送，改走安全路徑：寫入整通道重送並以 CRC 確認，讀取從第一個缺漏處設好指標後續讀。
  - CRC 指令只輪詢 STATUS。
  - 結果：8 通道 × 131072 點下載含 CRC 從 0.35 s 降到 0.16 s；8 通道 × 65520 點讀回從約 85 ms 降到 42 ms。

## 2026-11-12 GUI 內速度只有 2–3 MB/s（E6b）

- **現象**：GUI 單通道下載 0.08 s（約 3 MB/s），擷取讀回約 2 MB/s；但直接用 `awg_eth` 量測，單通道讀回只要 4.5 ms（約 29 MB/s）。
- **原因 1：GIL 爭用。** 背景執行緒每收一個 UDP 回覆都要重新取得 GIL。GUI 主執行緒在繪圖時，預設 5 ms 的切換間隔讓每個封包都要等。
  - 板上重現（離屏 MainWindow，主執行緒 100% 忙碌）：單通道讀回 5.9 ms → 約 400 ms。
  - 修正：`DeviceWorker` 把 `sys.setswitchinterval` 設為 0.1 ms。同樣條件下單通道讀回 4.7 ms、8 通道約 40 ms。
- **原因 2：主機端純 Python 計算。** 單通道下載 23 ms 中，CRC 計算佔 9.5 ms、tuple 轉換佔 4 ms，真正寫入只有 6.7 ms。
  - 修正：CRC 改成整段大整數遮罩後再呼叫 `binascii.crc32`（64 K 字約 2 ms），結果與原實作逐位一致；已是 32 位元整數就不再轉換。
- **原因 3：殘留的 arm。** 起播同步的擷取若逾時或被取消，板子會停在已 arm 的狀態（CAP_STATUS=5），下一次寫 CAP_CTRL 會回 SLVERR。
  - 修正：`capture_raw` 擷取前若發現 busy/armed 就先 abort，出錯時也會 abort。模擬器改成與硬體一致（armed 時 busy=1，CAP_CTRL 回錯）。
- `wait_capture_done` 前 50 次輪詢不 sleep，之後才每次 sleep 1 ms。
- **顯示**：下載與擷取都分開列出「共 … ms」和「其中資料寫入/讀回 … ms（MB/s）」。
- **板上結果**（GUI 主執行緒 100% 忙碌 / 閒置）：
  - 單通道 131072 點下載含 CRC：18 / 14 ms，資料寫入 31 / 39 MB/s；
  - 單通道 65520 點讀回：4.7 / 4.5 ms；
  - 8 通道讀回：約 40 / 36 ms。
- 詳見 `reports/E6_GUI/gil_fix.md`。

## 2026-11-12 一鍵下載 bit 並初始化（E6c）

- 選單「设备 → 下载 bit 并初始化…」（Ctrl+F5），使用者確認後：
  1. 斷開光口並停止連續擷取；
  2. 以 QProcess 執行 `xsct scripts/program.tcl [-server X] -package <固件包>`。
     - 環境變數 `PROCESSOR_ARCHITECTURE=AMD64`；
     - 輸出逐行寫到日誌（`[xsct] …`）；
     - 以 `RF initializer is running` 判斷成功。
  3. 背景執行緒每 0.5 s 嘗試連光口，直到 `STATUS.ps_ready=1` 才自動連線，最多等 120 s。
     - program.tcl 在 PS 完成 RFDC/MTS 之前就會返回，所以要等。
- 可以中途「取消初始化」。取消後板子可能停在半初始化狀態，需要重新下載。
- 可設定：
  - 固件包目錄，預設 `build/F1/package`，會檢查 4 個檔案；
  - XSCT 路徑：依序找已存設定、`XILINX_VITIS`、PATH、`D:\AMDDesignTools\2025.2\Vitis\bin\xsct.bat`；
  - hw_server 地址：留空時由 xsct 自動啟動本機 hw_server。
- 測試：
  - 用假的 xsct.bat 配合模擬器跑完整流程，包含失敗路徑；
  - 真的 xsct.bat 以只 `puts` 的 Tcl 試跑過，沒有碰 JTAG；
  - 2026-11-12 上板實測 3/3 成功（E7，exe `--program --yes`，每次 25–28 s，燒錄後確認板子確實重設），見 `reports/E7_ONECLICK`。
- V1.2：日誌同時寫檔（`%APPDATA%\awg_gui_v1\logs`）；命令列 `--program [--yes]`；`--selftest`；exe 旁 `firmware\` 自帶固件包；xsct 會掃描各磁碟。
