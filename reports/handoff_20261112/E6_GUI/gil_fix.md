# E6b：GUI 內速度 2–3 MB/s 的原因與修正（2026-11-12，D3C 位元流）

量測腳本：`reports/E6_GUI/gui_board_timing.py`。用離屏 `MainWindow` 對板子（192.168.42.2）執行。
參數 `busy` 表示讓主執行緒在等待迴圈裡做純 Python 運算，模擬 GUI 繪圖佔用 CPU；參數 `si=` 用來覆寫 GIL 切換間隔。

| 條件 | 單通道讀回 | 8 通道讀回 | 單通道下載（含 CRC） |
|---|---|---|---|
| 直接呼叫 `awg_eth`（無 GUI） | 4.5–5.2 ms | — | 22.8–23.6 ms（寫入 6.6–6.8 ms，主機 CRC 9.5–10.5 ms，tuple 4 ms） |
| 舊程式，GUI 閒置 | 5.2–5.9 ms | 37.8–41.4 ms | — |
| 舊程式，GUI 忙碌 | 375.9–417.7 ms | 2707–2990 ms | 67.9–75.9 ms（只修了切換間隔，CRC 尚未修） |
| 忙碌 + switchinterval 0.5 ms | 36.6–44.8 ms | 123.7–205.6 ms | — |
| 忙碌 + switchinterval 0.1 ms | 5.9–8.9 ms | 43.9–48.7 ms | — |
| 新程式，GUI 忙碌 | 4.6–4.7 ms | 38.0–40.6 ms | 17.7–20.3 ms（寫入 8.3–9.7 ms） |
| 新程式，GUI 閒置 | 4.4–4.6 ms | 35.7–36.5 ms | 13.7–16.1 ms（寫入 6.4–7.7 ms） |

每格是 3 次的範圍。主機測試共 34 個，全部通過（`py -X utf8 -m pytest -q awg_eth/tests awg_gui/tests`）。

另外，開始量測時板子停在 CAP_STATUS=5（起播觸發已 arm 但沒觸發），寫 CAP_CTRL 會回 SLVERR。
送出 COMMAND=32 後恢復正常；`capture_raw` 現在會自動處理這種情況。
