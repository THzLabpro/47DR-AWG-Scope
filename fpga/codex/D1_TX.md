# D1_TX — TX 子系統 `awg_tx`（URAM 14 bit 打包、9.8 GS/s 播放）

先讀 `AGENTS.md`、`doc/01_DATAPATH_V2.md`（§1、§2、§3 凍結）。參考 v1 行為：`rtl/awg_player.sv`、`rtl/axis_wide_gearbox.sv`、`rtl/awg_subsystem.sv`（唯讀）。

## 歸屬檔案（只能寫這些）

- `rtl/tx/**`（`awg_tx.sv` 為頂層，可拆子模組，一條管線一個檔，不要過度拆分）
- `sim/tx/**`、`build/D1/**`、`reports/D1/**`

## 要做的

1. `awg_tx`：埠 = doc/01 §3 的 host 側介面 + `dac_clk/dac_resetn`、`tx_clk/tx_resetn`（同源 ÷2，同相）、`host_clk/host_resetn` +
   RFDC 側 `dac_tdata[8*256-1:0]`、`dac_tvalid[7:0]`、`dac_tready[7:0]`（每通道 16 樣點 × 16 bit，`[15:0]` 為最早樣點）+ `tx_start_event`（dac_clk 單拍）、`tx_play_word[11:0]`（tx_clk）+ `ps_config_done`。
   - URAM：每通道 7 塊 URAM288 並排（以 `(* ram_style="ultra" *)` 推論或 XPM_MEMORY；必須真的落在 URAM，不得變成 BRAM/LUTRAM），讀出加足夠管線暫存器（URAM 輸出暫存器 + 至少一級）。
   - 寫入：host 域 → tx_clk 域 CDC（非同步 FIFO，有背壓），在 tx_clk 打包 16 個 32 bit 字 → 448 bit 寫入。
   - 2:1 寬度轉換 tx_clk(512) → dac_clk(256)：兩時鐘同源同相，用 dac_clk 域的相位暫存器選半邊（不得用非同步 FIFO 增加不確定延遲，除非報告說明原因）。dac_clk 域只允許：相位翻轉暫存器、2:1 選擇、輸出暫存器。
   - 播放器：沿用 v1 語意（start/stop/clear_fault、所有啟用通道同拍起播、無縫循環、停止輸出 0、`dac_tready` 掉下時記 underflow fault）。
   - CRC-32 引擎（doc/01 §3 定義）在 tx_clk 讀 URAM，只在停止時可用。
   - 控制/狀態跨域用 v1 的 request/acknowledge mailbox 或 XPM CDC；所有多 bit CDC 必須是 bundled-data 或 gray/握手，不得直接同步。
2. TB（xsim，`sim/tx/run.ps1` 一鍵）：時鐘 dac 612.5、tx 306.25（同源）、host 100 MHz。
   - T1 寫入：8 通道各寫不同的已知波形（含 ±8191 邊界、低 2 bit 非零以驗證截斷），長度 32、4096×32/2 和 131072 點各一。
   - T2 播放：比對 RFDC 側輸出樣點序列與期望（14 bit 截斷後 MSB 對齊），含循環邊界、8 通道同拍起播（同一 dac_clk 拍第一個有效樣點）、mask 只開部分通道。
   - T3 CRC：TB 用 SystemVerilog 計算期望 CRC（同 doc 規則）並比對；另外提供一個 Python 參考實作 `sim/tx/crc_ref.py`（`py -X utf8`），對同一波形印出 CRC，兩者一致。
   - T4 鎖定：執行中寫入/改長度被拒（h_locked）；寫入不足時 start 被拒（h_start_rejected）。
   - T5 underflow：中途拉低 dac_tready → fault，clear 後恢復。
   - T6 寫入背壓：host 側連續送 131072 點不停頓，無資料遺失；量測 host 域可接受的字率。
3. OOC 綜合 + impl（`xczu47dr-fsve1156-2-i`，dac_clk 612.5、tx_clk 306.25 由同一來源 generated clock、host 100 MHz），報告 WNS/WHS 分時鐘域、URAM/BRAM/LUT/FF。OOC 結果僅作參考，正式時序以整片為準。

## 驗收（固定）

1. T1–T6 全 PASS（`reports/D1/` 有日誌）；CRC 與 Python 參考一致。
2. URAM = 56、TX 部分 BRAM = 0（CDC FIFO 用 LUTRAM 或 BRAM 寫明數量）。
3. OOC impl：612.5/306.25/100 MHz 三域 WNS ≥ 0；若不收斂，報告最差路徑並停在 NEEDS_PARENT_JUDGMENT。
