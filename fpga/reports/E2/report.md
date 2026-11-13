# E2_ETH_CORE 執行報告

日期：2026-11-11  
狀態：`PASS`

## 完成項目

- `rtl/eth/awg_udp_port.v`：以 `udp_complete_64` 建立精簡 9100 UDP app；RX app 長度轉成不含 UDP header 的 payload 長度，TX 長度反向補回 8 bytes；其他本機 UDP 埠丟棄並計數。
- `rtl/eth/awg_eth_core.v`：整合 `demo_management_clock`、`optical_port2_exdes`、`xpm_cdc_async_rst`、RX/TX frame FIFO 與 UDP app 介面。RX FIFO 啟用 `DROP_BAD_FRAME`、`DROP_WHEN_FULL`，未加入 PAUSE 或 biz 邏輯。
- `rtl/eth/awg_eth_frame_pad.v`：E2 所屬的 64-byte 短幀補零器；用飽和 7-bit byte counter 取代原參考補幀器的長度/填充決策鏈。
- `constraints/eth/awg_eth_core.xdc`：QSFP2 腳位與板級屬性。156.25 MHz refclk 由匯入的 optical-port XCI 約束，沒有重複建立 clock，也沒有新增 false-path 或 clock-group 例外。
- `sim/eth_core/tb_awg_udp_port.sv`、`run.ps1`：256-bit AXIS 幀注入、echo app、T1–T6 自檢與一鍵 xsim。
- `sim/eth_core/run_ooc.ps1`、`build/E2/ooc_synth.tcl`：在 `build/E2` 臨時工程匯入三份 XCI 副本並執行 OOC 綜合，不修改 `ip/eth/*.xci` 原檔。

## 固定驗收

模擬命令：`powershell -NoProfile -ExecutionPolicy Bypass -File sim\eth_core\run.ps1`

| 驗收 | 結果 |
|---|---|
| T1 ARP request/reply | PASS，MAC/IP 與 ARP opcode 正確 |
| T2 UDP 9100，24/1048/8216 bytes | PASS，app header/payload、回覆 MAC/IP/UDP 與 IPv4 checksum 正確 |
| T3 UDP 9000 丟棄與計數 | PASS，`rx_udp_other=1`，未交付 app 或產生回覆 |
| T4 `tuser=1` 壞幀丟棄 | PASS，RX frame FIFO 丟棄，沒有 app header 或回覆 |
| T5 32 個 1048-byte UDP 背靠背 echo | PASS，32 個 payload 全數回送，無死鎖 |
| T6 IPv6 Ethertype 丟棄 | PASS，沒有 app header 或回覆 |

最終 xsim 計數：`rx_frames=38`、`rx_udp_9100=35`、`rx_udp_other=1`、`rx_non_ip=2`、`tx_frames=36`、`app_headers=35`、`app_payloads=35`、`app_payload_bytes=42824`；TB `errors=0`。`rx_frames` 是通過 RX frame FIFO 並進入 UDP port 的有效幀數，因此不含 T4 被前級 FIFO 丟棄的壞幀。

T2 三種 payload 的 UDP checksum 均為計算值，非零 checksum 分別為 `0x0856`、`0xff56`、`0xc05d`；三者的 pseudo-header/UDP checksum fold 均為 `0xffff`。實際輸出記錄在 `E2_xsim.log`。

OOC 命令：`powershell -NoProfile -ExecutionPolicy Bypass -File sim\eth_core\run_ooc.ps1`

| 項目 | 結果 |
|---|---|
| Device | `xczu47dr-fsve1156-2-i` |
| 綜合錯誤 | 0 |
| WNS / TNS | `+0.586 ns` / `0.000 ns`，0 failing endpoints |
| LUT / FF | 14,731 / 17,618 |
| BRAM / URAM | 5.5 tiles / 12 |
| GT | XCI 設定 `Quad_X0Y2`；4 個 GTYE4_CHANNEL 位於 X0Y8–X0Y11，另有 1 個 GTYE4_COMMON |

資源與 timing 原始報告在 `build/E2/utilization.rpt`、`timing_summary.rpt`、`timing_paths.rpt` 和 `gt_locations.rpt`。綜合階段為 0 errors、0 critical warnings、334 warnings。Vivado run log 另有 generated HDL 重複加入 project fileset 的 file-management critical warning；`synth_design` 完成且 timing/report 驗收通過，該 warning 保留在 `E2_ooc_synth.log` 供審查。

## E1 介面逐信號對照

E1 依 `rtl/eth/awg_eth_bridge.sv` 的實際 port 宣告；方向均以各模組本身為準。

| 信號 | E1 `awg_eth_bridge` | E2 `awg_eth_core` | 寬度/語義 |
|---|---|---|---|
| `clk_eth` | input | output | 1，Ethernet/app clock |
| `rst_eth` | input | output | 1，同步高有效 |
| `rx_hdr_valid` | input | output | 1，RX header valid |
| `rx_hdr_ready` | output | input | 1，RX header ready |
| `rx_src_ip` | input | output | 32 |
| `rx_src_port` | input | output | 16 |
| `rx_length` | input | output | 16，UDP payload bytes |
| `rx_payload_tdata` | input | output | 64 |
| `rx_payload_tkeep` | input | output | 8 |
| `rx_payload_tvalid` | input | output | 1 |
| `rx_payload_tready` | output | input | 1 |
| `rx_payload_tlast` | input | output | 1 |
| `rx_payload_tuser` | input | output | 1，1 表示壞幀 |
| `tx_hdr_valid` | output | input | 1，TX header valid |
| `tx_hdr_ready` | input | output | 1，TX header ready |
| `tx_dst_ip` | output | input | 32 |
| `tx_dst_port` | output | input | 16 |
| `tx_length` | output | input | 16，UDP payload bytes |
| `tx_payload_tdata` | output | input | 64 |
| `tx_payload_tkeep` | output | input | 8 |
| `tx_payload_tvalid` | output | input | 1 |
| `tx_payload_tready` | input | output | 1 |
| `tx_payload_tlast` | output | input | 1 |
| `tx_payload_tuser` | output | input | 1 |

## ARP 與待協調事項

靜態後備為 `192.168.42.10 -> 6c:b3:11:21:7d:8e`。只讀 v3 `arp.v` 會將收到的有效 ARP sender IP/MAC 寫入動態 cache；本機目標 ARP request 直接回覆到該 request 的 sender MAC/IP。後續 UDP TX 查詢先使用動態 cache，未命中時可使用靜態後備。因此 sender IP 不同於靜態 IP 時，v3 ARP 有動態學習路徑可供解析；T1 實際使用的是靜態 host `.10`，不同 sender IP 未另作測試。

唯一語義需上游確認：本報告將 `rx_frames` 定義為進入 `awg_udp_port` 的有效幀數，所以壞幀由 core RX FIFO 丟棄後不增加此計數器。若期望它代表 MAC 端包含壞幀的原始 frame event，應由 core 在 RX FIFO 前另行計數。

未執行硬體操作、host network 發包或板上測試。初次 OOC 工程嘗試曾觸發 XCI output remap 訊息；改為 `import_ip` 後，最終生成目錄均在 `build/E2`。收尾檢查 `D:\ClaudeProject\rfudp_c5.gen` 不存在。中間 OOC 嘗試的診斷 log 以 `E2_ooc_synth_*.backup.log` 保留。

## 日誌與產物

- `reports/E2/E2_xvlog.log`、`E2_xelab.log`、`E2_xsim.log`、`E2_ooc_synth.log`
- `build/E2/utilization.rpt`、`timing_summary.rpt`、`timing_paths.rpt`、`gt_locations.rpt`
- 狀態摘要：`reports/E2/status.json`
