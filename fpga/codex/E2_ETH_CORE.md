# E2_ETH_CORE — QSFP2 40G MAC 包裝 + 精簡 UDP 堆疊（只收 9100）

先讀 `AGENTS.md`、`doc/00_ETH_PLAN.md`（§2、§3、§4.1 凍結）。

## 背景

`rf_udp_link_v3` 的光口在本板 QSFP2 與 PC XL710 已上板跑通。相關原始碼已複製（唯讀）到：

- `rtl/eth/v3_qsfp2/`：`optical_port2_exdes.v`（MAC 包裝）、`udp_complete_64.v`/`ip_complete_64.v`/`arp.v`（v3 修過的 verilog-ethernet，含靜態 ARP 和 header-only 修正）、
  `axis256_to_axis64.v`、`axis64_to_axis256.v`、`axis_eth_frame_align_pad_64.v`、`udp_arp_axis256_port.v`（參考接法）等
- `rtl/eth/vendor/verilog-ethernet/`：v3 用的上游模組子集
- `ip/eth/{optical_port2,demo_management_clock,optical_port1_clk_wiz_0}/*.xci`
- `constraints/eth/qsfp2_udp_echo*.xdc`（管腳和 CDC）
- 參考（唯讀，不要複製 RFU 相關邏輯）：`D:/ClaudeProject/rf_udp_link_v3/rtl/eth/rfudp_eth_core_v3.v`、`rtl/eth/qsfp2/rtl/udp_arp_axis256_port_v3.v`

## 歸屬檔案（只能寫這些）

- `rtl/eth/awg_eth_core.v`、`rtl/eth/awg_udp_port.v`（以及必要的 `rtl/eth/awg_eth_*.v` 小模組，但不得與 E1 的 `awg_eth_bridge*.sv` 重名）
- `constraints/eth/awg_eth_core.xdc`
- `sim/eth_core/**`、`build/E2/**`、`reports/E2/**`

## 要做的

1. `awg_udp_port`（clk_eth 域）：256 bit MAC AXIS RX/TX ↔ plan §4.1 的 64 bit UDP app 介面。
   - 從 `udp_arp_axis256_port.v` 精簡：保留 256→64、eth_axis_rx、udp_complete_64（含 ARP 應答；參數化 `LOCAL_MAC/LOCAL_IP/STATIC_ARP_IP/STATIC_ARP_MAC`，預設值見 plan §3）、eth_axis_tx、frame align/pad、64→256。
   - 去掉 RFU/biz/echo/telemetry。只把 目的埠=9100 的 UDP 交給 app；其他 UDP 丟棄並計數。
   - TX 回覆的目的 MAC 用 ARP（v3 的 ARP 快取 + 靜態後備）。請求來源的 IP 若與靜態 IP 不同，也要能經 ARP 解析後回覆（說明 v3 arp.v 是否支援；不支援就報告，不要自己大改）。
   - 輸出狀態計數：rx_frames、rx_udp_9100、rx_udp_other、rx_non_ip、tx_frames（32 bit 飽和）。
2. `awg_eth_core`：仿 `rfudp_eth_core_v3.v`，包含 `demo_management_clock`、`optical_port2_exdes`、`xpm_cdc_async_rst` 復位、RX frame FIFO（`DROP_BAD_FRAME`、`DROP_WHEN_FULL`）、`awg_udp_port`、TX frame FIFO。
   - 不要 PAUSE 和 biz 邏輯。對外：QSFP2 管腳（`qsfp2_*`，與 v3 xdc 同名）、`sys_reset`、`clk_eth`/`rst_eth` 輸出、§4.1 app 介面、狀態（rx_gt_locked、rx_aligned、計數器）。
   - `constraints/eth/awg_eth_core.xdc`：從 v3 的兩個 xdc 整理成本頂層可用的版本（管腳、refclk 156.25 MHz、必要 CDC）；說明哪些約束依賴頂層名稱。
3. TB（xsim）：測 `awg_udp_port`（不模擬 MAC IP）。
   - 在 256 bit MAC 介面注入以太網幀（TB 自己組幀，含正確 IP/UDP checksum），app 側接一個 echo 模型（把負載原樣回送到請求來源）。
   - 場景：T1 ARP request（目標 192.168.42.2）→ 正確 ARP reply；T2 到 9100 的 UDP（長度 24、1048、8216 位元組）→ app 收到正確頭和負載，echo 回來的幀 MAC/IP/UDP 欄位、IP checksum 正確（UDP checksum 為 0 或正確皆可，報告是哪種）；
     T3 到 9000 的 UDP → 丟棄、計數；T4 壞 FCS/tuser=1 的幀 → 丟棄；T5 連續 32 個 1048 位元組 UDP 背靠背 → 全部 echo 正確，無死鎖；T6 非 IPv4（IPv6 ethertype）→ 丟棄。
4. `awg_eth_core` 的 OOC 綜合（含 IP 生成，`xczu47dr-fsve1156-2-i`），報告資源和 WNS。產生 IP 時用 `build/E2/` 下的暫存工程，不要改 `ip/eth/*.xci` 原檔；若 IP 需要升級，報告升級結果。

## 驗收（固定）

1. T1–T6 全 PASS，日誌在 `reports/E2/`；`sim/eth_core/run.ps1` 一鍵重跑。
2. `awg_eth_core` OOC 綜合 0 error、WNS ≥ 0；報告 LUT/FF/BRAM/URAM 和 GT 位置（應為 Quad_X0Y2）。
3. 報告說明 ARP 行為（靜態/學習），以及與 E1 的介面對照表（逐信號）。
