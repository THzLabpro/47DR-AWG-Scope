# D3A_INTEGRATION 執行報告

日期：2026-11-11  
狀態：`NEEDS_PARENT_JUDGMENT`

## 完成項目

- `rtl/tx/awg_tx.sv`：把 host_clk→tx_clk 的 35-bit、64 深度手寫非同步 FIFO 換成 `xpm_fifo_async`，採用 64 深度 block FIFO、標準讀取模式與 1 拍讀延遲。讀端先把 FIFO 輸出鎖入 `fifo_data_stage`，再交給打包器。
- `rtl/rx/awg_rx.sv`：增加 `dac_clk`、`tx_clk`、`tx_resetn` 輸入；起播 toggle 由 dac_clk 同步至 rx_clk；`tx_play_word` 以 `xpm_cdc_handshake` 從 tx_clk 傳至 rx_clk，來源資料在 handshake 完成前保持穩定。
- `sim/rx/tb_awg_rx.sv`：補上 DAC/TX clock 與 reset 激勵，量測 `CAP_TX_WORD` 對起播位置的循環誤差，門檻依任務規格設為 16 字。
- `reports/D3A_INTEGRATION/`：保存本任務 TX/RX 編譯、elaboration 與模擬日誌，以及本報告和狀態檔。

## 執行命令與結果

Vivado 2025.2 執行前設定 `PROCESSOR_ARCHITECTURE=AMD64`、`NoDefaultCurrentDirectoryInExePath=$null`。兩個 testbench 分別在 `build/D3A_INTEGRATION/sim_tx/`、`build/D3A_INTEGRATION/sim_rx/` 執行；XPM CDC/FIFO 使用 Vivado `glbl.v`。

- TX：`xvlog -sv -L xpm ... awg_tx_uram_block.sv awg_tx.sv tb_awg_tx.sv glbl.v`、`xelab -L xpm work.tb_awg_tx work.glbl ...`、`xsim tb_awg_tx_sim -runall`。最終結果 `PASS=26 FAIL=0 mismatches=0 x_count=0`；T1–T6 全通過，CRC `crc_dut=d49307a0 crc_sv=d49307a0`（`D49307A0`）。第一次 RTL regression 因 XPM 標準讀模式的 valid 取樣方式不符而失敗，按 FIFO `FIFO_READ_LATENCY=1` 加入讀出暫存後重跑通過。另一次初始 elaboration 缺少 `glbl`，補入後正常完成。
- RX：`xvlog -sv -L xpm ... awg_rx.sv tb_awg_rx.sv glbl.v`、`xelab -L xpm work.tb_awg_rx work.glbl ...`、`xsim tb_awg_rx_sim -runall`。最終 `compared=543552 mismatches=0 x_count=0 pass_items=21 fail_items=3`。R1/R3/R4 通過；R2 20 次中 17 次通過、3 次循環誤差為 17 字，超出固定 16 字門檻 1 字。最大實測誤差 17 字。第一次 R2 regression 的來源 handshake 只送單拍 `src_send`，導致快照停在首次值；改為遵守 XPM 的 `src_send`/`src_rcv` 完整握手後重跑，仍未達門檻。
- Vivado Simulator 的 RX 編譯/elaboration 無錯誤；最終 RX 模擬退出碼為 0，但 TB 自檢結果為 FAIL。沒有執行硬體操作、`hw_server`、JTAG 或對 `192.168.42.x` 發包。

## 固定驗收狀態

| # | 驗收 | 結果 | 實際狀態 |
|---|---|---|---|
| 1 | TX T1–T6、RX R1–R4 | FAIL | TX 26/26 PASS；RX R1/R3/R4 PASS，R2 17/20 PASS，最大誤差 17 字（限值 16）。 |
| 2 | `awg_control_v2` 單元 TB | 未做 | 到達 D3A 固定停止條件前未建立控制器或 TB。 |
| 3 | 系統模擬 S1–S7 | 未做 | 未建立系統 TB。 |
| 4 | `synth_design -rtl`、BD diff、約束語法/命中 | 未做 | 未建立正式頂層、D3 建置腳本與 top 約束；未執行 Vivado elaboration。 |
| 5 | 資源估算 | 已彙整前序數據，未完成 D3A 統整驗證 | 見下表；E1 OOC FIFO 深度與 D3 設定不同，數據只能作參考。 |
| 6 | 單一失敗最多修 2 輪 | STOP | RX R2 的同一 16-word 誤差門檻在兩次執行後仍失敗，依規則停止並交由 parent 判斷。 |

## 前序資源估算

數字只取已簽核前序報告，不是本任務新跑的綜合結果。RAMB36 等效按 RAMB36 + RAMB18/2 計。

| 子系統 | URAM | RAMB36 等效 | GT | 來源/限制 |
|---|---:|---:|---:|---|
| TX 播放緩衝 | 56 | 0 | 0 | `reports/D1R2_TX/report.md` |
| RX 擷取緩衝 | 0 | 228 | 0 | `reports/D2/report.md`：224 RAMB36 + 8 RAMB18 |
| Ethernet bridge | 0 | 27.5 | 0 | `reports/E1R2_BRIDGE/report.md`；前序 OOC 使用的 RX FIFO 深度大於 D3A 指定值，不能視為 D3 精確值 |
| Ethernet MAC/UDP | 12 | 5.5 | 4 channel + 1 common | `reports/E2/report.md` |
| 前序數據算術合計 | 68 | 261 | 4 channel + 1 common | 非 D3A 綜合結果；D3A 配置需由後續綜合確認 |

器件前序資料列為 URAM=80、RAMB36=1080、GTY channel=16；因此前序數據的估算合計低於器件總量。此表不替代 D3A 指定的正式整合資源報告。

## 未完成與需協調

- R2 實測有 3/20 次 `CAP_TX_WORD` 誤差為 17 字，固定上限為 16 字。此失敗已達兩次執行上限；不得在本任務內再改第三輪，請 parent 判斷後續應調整握手更新頻率或誤差定義。
- `awg_control_v2`、正式頂層、D3 系統 TB、top constraints、`build_d3.tcl`、`synth_design -rtl` 與 BD 參數 diff 尚未實作/執行。
- 無其他規範歧義已確認；`awg_rx` 額外增加 `dac_clk` 與 `tx_resetn`，是為使 DAC 起播 toggle 與 TX 來源 handshake 分別使用正確來源時鐘及本域 reset。
