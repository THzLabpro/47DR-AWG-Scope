# D2_RX — RX 子系統 `awg_rx`（BRAM 14 bit 打包、5 GS/s 擷取）

先讀 `AGENTS.md`、`doc/01_DATAPATH_V2.md`（§1、§2、§4 凍結）。參考 v1：`rtl/candidates/dac9g_capture_fix/adc_capture.sv`（唯讀，已上板驗證的擷取語意）。

## 歸屬檔案（只能寫這些）

- `rtl/rx/**`（`awg_rx.sv` 為頂層）
- `sim/rx/**`、`build/D2/**`、`reports/D2/**`

## 要做的

1. `awg_rx`：埠 = doc/01 §4 的 host 側介面 + `adc_clk/adc_resetn`（416.667）、`rx_clk/rx_resetn`（÷2 同源同相）、`host_clk/host_resetn` +
   RFDC 側 `adc_tdata[8*192-1:0]`、`adc_tvalid[7:0]`（每通道 12 樣點 × 16 bit，`[15:0]` 最早）+ `tx_start_event_toggle`（來自 TX，非同步 toggle）、`tx_play_word[11:0]`（來自 tx_clk，非同步，只做粗略取樣，用 gray 或握手）。
   - adc_clk 域只允許：輸入暫存器、相位暫存器、1:2 加倍（兩拍併成 384 bit 交給 rx_clk）。
   - rx_clk 域：取每樣點高 14 bit 打包為 336 bit，寫入每通道 2730×336 的 BRAM（簡單雙埠，讀口在 host_clk）。必須推論成 BRAM（報告實際 RAMB36/18 數）。
   - 觸發：trig_mode 0/1 照 doc；arm 時取樣 cap_words 和 trig_mode；完成後 done=1、busy=0（與 v1 一致，state=2 表示成功）。
   - 讀出：`h_rd_pair` 為樣點對索引，回傳兩個 int16（MSB 對齊、低 2 bit 為 0）；固定延遲 ≤ 4 拍。
2. TB（`sim/rx/run.ps1`）：adc 416.667、rx 208.333（同源）、host 100 MHz。ADC 模型每通道送可預測序列（每通道不同的 14 bit 遞增 + 偽隨機低 2 bit 雜訊）。
   - R1 手動觸發，cap_words = 1、100、2730；讀回全部 8 通道逐點比對（容許的起點：arm 後第一個 24 點邊界，TB 用 ADC 序列值反推起點，檢查連續無漏點）。
   - R2 DAC 起播觸發：TB 在任意時刻送 tx_start_event_toggle，檢查擷取起點與事件的延遲在 doc 允許範圍內，跑 20 次隨機相位，報告延遲分佈。
   - R3 擷取中再 arm → 被忽略/報告；擷取中讀取 → 讀到的是舊資料或被拒（寫明行為）。
   - R4 adc_tvalid 中途掉 → 擷取暫停或標記（照 v1：只在全部 valid 時寫入），報告行為。
3. OOC 綜合 + impl（adc_clk 416.667、rx_clk 208.333 同源、host 100 MHz），報告 WNS/WHS、BRAM/LUT/FF。

## 驗收（固定）

1. R1–R4 全 PASS 或行為已明確記錄；日誌在 `reports/D2/`。
2. BRAM 用量 ≤ 8×30 RAMB36（報告實際值）。
3. OOC impl 三域 WNS ≥ 0；不收斂則報告最差路徑，NEEDS_PARENT_JUDGMENT。
