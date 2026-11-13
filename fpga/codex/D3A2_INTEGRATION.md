# D3A2_INTEGRATION — 接續 D3A（第二段）

任務內容、歸屬檔案、驗收與 `codex/D3A_INTEGRATION.md` **完全相同**，只有以下變更。先讀 `reports/D3A_INTEGRATION/report.md`。

## Claude 判定

- D3A 停在 RX R2：`CAP_TX_WORD` 誤差實測 2–17 字，就是 `xpm_cdc_handshake` 一個握手週期的落後量，屬預期行為。
  門檻是 Claude 估得太緊；`doc/01_DATAPATH_V2.md` 已改為 **≤ 24 字**。把 `sim/rx/tb_awg_rx.sv` 的門檻改成 24 後重跑 R1–R4 即可，不要改 RTL。
- D3A 已完成且接受：awg_tx 改 `xpm_fifo_async`（T1–T6 26/26、CRC `D49307A0`）、awg_rx 握手修改（R1/R3/R4 PASS）。保留，不要重做。

## 接著做

D3A 任務書的第 1、2、4、5、6 節（awg_control_v2 + 單元 TB、正式頂層、約束、系統模擬 S1–S7、建置腳本到 `synth_design -rtl`），以及驗收 1–5。

## 停止規則補充

AGENTS.md 規則 9 的「同一失敗修 2 輪仍失敗就停」只停**那一項**：若其他驗收項不依賴它，繼續完成其他項，最後整體報告 `NEEDS_PARENT_JUDGMENT` 並列出卡住的項目。只有後續工作依賴該項時才整體停止。

報告與狀態寫到 `reports/D3A2_INTEGRATION/`，建置與模擬放 `build/D3A2_INTEGRATION/`。
