# D3C_IMPL — 修正 E5 上板發現的問題 + 重新實現

結論：**PASS（建置）**。三項 RTL 修正都已完成、模擬全過、時序收斂，bit/XSA/韌體套件已產生。新 bit 尚未上板，需使用者同意。執行者是 Claude。

## 修正

| # | E5 問題 | 修正 | 檔案 |
|---|---|---|---|
| A | MAC 最大幀 1518 B，不收 jumbo | `ctl_rx_max_packet_len_0` 從 1518 改成 9600 | `rtl/eth/v3_qsfp2/optical_port2_exdes.v` |
| B | 寫 CAP_RD_CH 不歸零讀指標 | 寫入 CAP_RD_CH 時 `selected_rd_pair`、`rx_h_rd_pair` 歸零（符合 doc/01 §5） | `rtl/ctrl/awg_control_v2.sv` |
| C | 讀指標越界讀 CAP_RD_DATA 會鎖死 AXI | 指標 ≥ 32760 時立即回 SLVERR；另加看門狗，awg_rx 15 拍內沒回應就回 SLVERR，`last_cmd_result=2` | `rtl/ctrl/awg_control_v2.sv` |
| — | D3B 最緊路徑（單顆 `adc_pair_valid_q` 跨域驅動 8 通道 CE，+5 ps） | 每通道一份 `adc_pair_valid_ch`（DONT_TOUCH），只驅動自己通道的寫入暫存器；原本那份只留給狀態機 | `rtl/rx/awg_rx.sv` |

其他：
- BUILD_ID 改成 `0xD3C0_2026`（控制器與橋接器）。
- 建置目錄改為 D3C_IMPL。
- 複本稽核新增 `adc_pair_valid_ch` 8 份。
- 主機庫：
  - 新增 `abort_capture()`（COMMAND=32）和 CLI `abort`；
  - 模擬器支援 COMMAND=32，越界讀回 SLVERR；
  - pytest 新增 1 項。
- doc/01 §5：CAP_RD_DATA 越界或逾時回 SLVERR。
- doc/00 §6：本板只引出 8 個 GTY。

## 模擬

| TB | 結果 |
|---|---|
| 控制器 | 57/0（新增 9 項 D3C：CAP_RD_CH 歸零、最後一對可讀、越界 SLVERR、之後匯流排仍可用、不回應時看門狗 SLVERR、之後可正常讀） |
| TX | 70/0 |
| RX | 29/0；R6 兩種 reset 相位延遲都是 12 點；545088 點 0 mismatch |
| 橋接 | 115/0（S10 59.3 MB/s） |
| 系統 | 245/0 |
| 主機 pytest | 14/14 |

TB 的 awg_rx 模型改成「越界請求不回 valid」，與實際 RTL 相同。舊模型對每個請求都回 valid，所以抓不到問題 C。

## 綜合與實現

- 綜合：0 error、0 CW。
- 複本稽核：8/32/32/8/8/8，加上 `adc_pair_valid_ch` 8 份，都沒被合併。
- 實現：第 1 次（預設策略加 phys_opt）就收斂。
  - WNS +0.011、TNS 0、WHS +0.010、THS 0。
  - 98842 個網路全部繞完。
  - DRC 0 error。
  - 沒有 Unsafe 跨時鐘路徑；methodology 只有 TIMING-54 ×1（光口 IP，已接受）。
  - dbg_hub 設定已生效。

| 時鐘 | WNS | WHS | D3B WNS |
|---|---|---|---|
| dac 612.5 MHz | +0.078 | +0.021 | +0.057 |
| tx_clk | +0.148 | +0.010 | +0.123 |
| adc 416.7 MHz | +0.139 | +0.033 | +0.257 |
| rx_clk | +0.457 | +0.036 | +0.464 |
| clk_pl_0 | +1.980 | +0.013 | +2.500 |
| txoutclk / rxoutclk | +0.322 / +0.624 | +0.013 / +0.013 | +0.089 / +0.723 |
| tx→dac / dac→tx | +0.125 / +0.160 | +0.028 / +0.099 | +0.175 / +0.129 |
| **adc→rx** | **+0.011** | **+0.013** | +0.005 |

- 最緊路徑仍是 adc→rx：`adc_pair_channels[0].adc_pair_valid_ch_reg[0]` → LUT6（AND 狀態）→ `channel_bram[0].channel_write_data_q` 的 CE。
  - 佈線 1.81 ns，skew −0.295 ns。
  - 每通道扇出約 336，比原本的 2700 小很多，但跨域預算只有 2.4 ns，餘量還是很薄。
- **建議的下一步**：讓 `channel_write_data_q` 每個 rx 拍無條件取樣（不接 CE），只有 `channel_write_enable_q` 由 valid 控制。功能等價，而且跨域的高扇出 CE 會完全消失。

## 資源（routed）

LUT 34048（D3B 33501）、暫存器 60157（60202）、Block RAM Tile 269、URAM 56、GTY 4，和 D3B 相同或差不多。

## 產物

| 檔案 | sha256 |
|---|---|
| `build/D3C_IMPL/awg_eth_v2.bit` | `A294A0D8BB436E228A855708F774854E40F5884D679207F0BB335221C9AFC079` |
| `build/D3C_IMPL/awg_eth_v2.xsa` | `72B1B7FD36924489AB9105A2B20D0A26AB45576DF3B4377E6BE20EC8F0724468` |
| `build/F1/package/`（D3C bit + 從 D3C XSA 重建的 BSP/ELF） | 見 `fw_artifacts.txt` |

D3B 上板用過的套件保留在 `build/F1/package_d3b/`。

## 未驗證

- 新 bit 還沒上板。jumbo（2048 字/包）的實際吞吐、CAP_RD_CH 歸零、越界 SLVERR 都需要上板確認，需使用者同意。
