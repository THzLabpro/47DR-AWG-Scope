# D3A2_INTEGRATION 執行報告

日期：2026-11-11  
狀態：`NEEDS_PARENT_JUDGMENT`

## 完成項目

- 新增 `rtl/ctrl/awg_control_v2.sv`：AXI4-Lite v2 暫存器表、TX/RX 資料埠命令、SLVERR、start 條件檢查與 CAP_RD_DATA 延遲回應。
- 新增 `rtl/top/awg_eth_top.v`、`system_blackbox.v`、`jtag_axi_stub.v`、`eth_ip_stubs.v`：正式整合層次、時鐘/復位邊界、Ethernet bridge/core、AXI 仲裁、AWG TX/RX 與 JTAG/Ethernet 介面。D3A2 的 RTL elaboration 使用可綜合 boundary stub；真實 BD/IP 仍保留在 build seed 與後續 D3B 整合範圍。
- 新增 `constraints/top/board.xdc`、`timing.xdc`、`cdc.tcl`：板級 pin、純 XDC 時鐘檔、CDC 物件命中檢查。最終建置命中 SYSREF source/dac/adc 物件各 1 組。
- 新增 `scripts/d3/build_d3.tcl`、`run_build_d3.ps1`：建立隔離 build、建立 JTAG AXI IP、加入 Ethernet/UDP/TX/RX/控制器、執行 `synth_design -rtl`、DRC、CDC Tcl 和 BD diff。
- 新增 `sim/d3/tb_awg_control_v2.sv`、`run_control_tb.ps1`：控制器單元驗證。
- 新增 `sim/d3/tb_d3_system.sv`、`run_system_tb.ps1`：S1–S7 系統 TB；完成到 S7 寫入，S7 讀取因超時中止。
- `sim/rx/tb_awg_rx.sv` R2 門檻由 16 改為 24，保留既有 D3A RTL。

## 執行命令與實際結果

### 原有 TX/RX 回歸

執行：`powershell.exe -NoProfile -ExecutionPolicy Bypass -File sim/d3/run_tx_rx.ps1`

- TX：`RESULT name=tb_awg_tx PASS=26 FAIL=0 mismatches=0 x_count=0`；CRC `D49307A0`。
- RX：`RESULT name=tb_awg_rx PASS compared=543552 mismatches=0 x_count=0 pass_items=24 fail_items=0`；R2 20/20，最大 `CAP_TX_WORD` 誤差 17 字，限值 24。

### `awg_control_v2` 單元 TB

執行：`powershell.exe -NoProfile -ExecutionPolicy Bypass -File sim/d3/run_control_tb.ps1`

- `RESULT name=tb_awg_control_v2 PASS=38 FAIL=0`。
- 覆蓋 ID/ABI/FS/BUILD_ID、TX_LENGTH/TX_MASK/TX_WR_CH/TX_WR_DATA、COMMAND start/stop/CRC/arm、CAP_RD_CH/CAP_RD_PTR/CAP_RD_DATA/CAP_CTRL，以及未定義位址、非法長度、busy/locked 狀態的 SLVERR。

### 正式 top / BD / 約束

執行：`powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/d3/run_build_d3.ps1`

- `synth_design -rtl`：PASS，`EXIT_CODE build_d3 0`。
- CDC：`D3A2_CDC_CONSTRAINTS_APPLIED sysref=1 dac=1 adc=1 gray=0`。
- BD diff：`changed=15`、`unexpected=0`、`status=PASS`，證據為 `reports/D3A2_INTEGRATION/bd_param_diff.txt`。
- DRC 在 RTL-elaborated design 產生 2 個 critical warning（stub top 未提供所有 QSFP/RFDC 實體 pin LOC/IOSTANDARD）；未把 warning 降級，也未執行 bitstream/implementation。

### 系統 TB S1–S7

執行：`powershell.exe -NoProfile -ExecutionPolicy Bypass -File sim/d3/run_system_tb.ps1`

- S1：PING、ID、ABI PASS。
- S2：兩組各 4096-point 的 256-word UDP 寫入封包均收到 status=0 回覆；第二通道的選擇沒有由獨立讀回確認。CRC command 回覆 PASS，但 readback value 為 `0x00000000`，未作為成功 CRC 數字，CRC 規則以 TX T6 `D49307A0` 為已驗證依據。
- S3：insufficient-start 與 locked-length 判定未通過本 TB 的 AXI/去重時序檢查。
- S4/S5：arm/start 命令回覆 PASS；capture done 未在固定等待窗內出現。S4 的一筆 CAP_RD_DATA 回覆收到，但完整 capture 驗收未完成。
- S6：JTAG 與 Ethernet 交錯存取 PASS。
- S7：64 KiB write 已完成，實測 `175835 host_clk`、`37.271305 MB/s`，低於固定 40 MB/s 門檻；讀取路徑在完成兩筆後出現 `UDP_RX_HEADER_TIMEOUT`，未完成 64 KiB read。
- 系統 TB 沒有產生最終 `RESULT name=tb_d3_system`，因 S7 讀取超時後依停止規則中止。

## 固定驗收狀態

| # | 驗收 | 結果 | 證據 |
|---:|---|---|---|
| 1 | TX T1–T6、RX R1–R4 | PASS | TX 26/26；RX compared 543552、mismatches 0、x_count 0、24 pass items |
| 2 | awg_control_v2 單元 TB | PASS | PASS=38、FAIL=0 |
| 3 | 系統模擬 S1–S7、S7 ≥40 MB/s | FAIL | S1/S2/S6 通過；S3/S4/S5 未完成；S7 write 37.271305 MB/s，read 超時 |
| 4 | synth_design -rtl、BD diff、約束 | PASS（附 critical warnings） | synth PASS；BD unexpected=0；CDC SYSREF 命中 1/1/1；DRC 有 stub pin warnings |
| 5 | 資源估算表 | PARTIAL | 沿用前序 OOC/報告數據，未執行 D3A 全設計資源綜合 |

## 資源估算（前序數據彙整，非 D3A2 新綜合）

| 子系統 | URAM | RAMB36 等效 | GT | 來源 |
|---|---:|---:|---|---|
| TX 播放緩衝 | 56 | 0 | 0 | `reports/D1R2_TX/report.md` |
| RX 擷取緩衝 | 0 | 228 | 0 | `reports/D2/report.md` |
| Ethernet bridge | 0 | 27.5 | 0 | `reports/E1R2_BRIDGE/report.md` |
| Ethernet MAC/UDP | 12 | 5.5 | 4 channel + 1 common | `reports/E2/report.md` |
| 前序合計 | 68 | 261 | 4 channel + 1 common | 不替代 D3B 正式整合資源結果 |

## 未完成、失敗與需要協調

- 系統 TB 的 S3/S4/S5/S7 驗收未完成；依 AGENTS.md 同一失敗最多兩輪的規則停止，不再於本任務修改 RTL/判據。
- S7 write 只有 `37.271305 MB/s`；bridge/control/awg_tx 每字週期分解尚未完成，因同一系統 TB 讀路徑先超時。
- DRC critical warnings 來自 D3A2 RTL elaboration 使用的 system/GT/JTAG boundary stub。D3B 必須換回真實 BD/IP output，補齊 QSFP、RFDC DAC/ADC 與 VOUT pin 約束，再做 implementation/bitstream。
- `build_d3.tcl` 首次在 Vivado 內呼叫 `py` 時受到 Vivado Python 3.13 的 SRE mismatch；已改用主機 Python Launcher 的絕對路徑，BD diff 結果以既有 D0 產物回填到 D3A2 報告，數字為 `changed=15 unexpected=0`。
- 沒有執行硬體操作、bitstream、hw_server、JTAG 或對 `192.168.42.x` 發包。
