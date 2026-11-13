# rf_awg_eth_v1 — 40GbE 光口取代 JTAG 的 AWG/Scope

2026-11-11 立項。來源：`../rf_awg_scope_v1`（9 GS/s DAC、5 GS/s ADC，已上板的 capfix9g 包）。
光口部分沿用 `D:/ClaudeProject/rf_udp_link_v3` 已在本板 QSFP2 上與 PC（Intel XL710 40G）跑通的 40G MAC 和 UDP 堆疊。

## 1. 目標與範圍

使用者選定「快速下載 + 循環播放」：

- PC 透過 QSFP2 40GbE 把波形寫進 FPGA 晶片上的播放緩衝，DAC 循環播放（行為與 v1 相同）。
- ADC 觸發擷取到晶片上的緩衝，擷取完成後透過 40GbE 回傳 PC。
- JTAG 只保留給初始化（PS/LMK/PL/MTS 流程不變）和備援除錯；資料傳輸不再走 JTAG。
- 降低晶片 RAM 佔用（第 2 期，見 §6）。

不在範圍內：連續串流、RFDC DUC/DDC、DDR 深儲存（之後另議）。

## 2. 架構

```
 PC (XL710, 192.168.42.10)
   │ 40GBASE-R4, QSFP2
 optical_port2 (l_ethernet 40G MAC+PCS, 256 bit AXIS, clk_eth = tx_clk_out 312.5 MHz)
   │ 256 bit
 awg_eth_core (clk_eth)：RX frame FIFO → axis256→64 → eth_axis_rx → udp_complete_64(ARP)
   │                       → 只收 UDP 9100 → app 介面（64 bit UDP payload + 頭欄位）
   │                       app TX → udp_complete_64 → eth_axis_tx → pad/align → 64→256 → TX FIFO
   │ 64 bit UDP app 介面（§4.1）
 awg_eth_bridge：clk_eth ↔ host_clk 非同步 FIFO + 命令引擎（host_clk）
   │ AXI4-Lite master（32 bit）
 axil_arb2：JTAG-AXI 與 Ethernet 兩個 master 輪詢仲裁（一次一筆）
   │
 awg_subsystem / awg_control（地址表與 v1 完全相同，不修改）
```

設計取捨：第 1 期刻意走 AXI4-Lite，沿用 v1 已驗證的記憶體/暫存器路徑，不碰 562.5 MHz DAC 域（v1 的 WNS 只有 +0.001 ns）。
理論吞吐約每 3 個 host_clk 週期一個字，100 MHz 下約 130 MB/s，1 MiB 波形約 8 ms，比 JTAG 快兩個數量級；PC 端軟體才是瓶頸。
需要更快時第 2 期再加 256 bit 直寫通道。

## 3. 網路參數（沿用 v3）

| 項目 | 值 |
|---|---|
| FPGA MAC / IP | `02:47:41:00:00:02` / 192.168.42.2 |
| PC IP | 192.168.42.10（v3 已設定好；靜態 ARP 後備：`6c:b3:11:21:7d:8e`） |
| UDP 埠 | FPGA 9100（AWG 協定）；其他埠丟棄並計數 |
| 回覆目的地 | 請求的來源 IP 與來源埠 |
| MTU | 預設 1500；FPGA 支援到 9000（巨型幀） |

## 4. 介面與協定（凍結；E1/E2/E3 必須一致）

### 4.1 UDP app 介面（clk_eth 域，E2 提供，E1 使用）

verilog-ethernet 慣例：`tdata[7:0]` 是線上第一個位元組。

RX（E2 → E1）：
`rx_hdr_valid/ready`、`rx_src_ip[31:0]`、`rx_src_port[15:0]`、`rx_length[15:0]`（UDP 負載位元組數）、
`rx_payload_tdata[63:0]`、`tkeep[7:0]`、`tvalid`、`tready`、`tlast`、`tuser`（1 = 壞幀，整包丟棄）。
只有目的埠 = 9100 且目的 IP = 本機的 UDP 才送出；頭和負載遵循 udp_complete_64 的握手順序。

TX（E1 → E2）：
`tx_hdr_valid/ready`、`tx_dst_ip[31:0]`、`tx_dst_port[15:0]`、`tx_length[15:0]`（負載位元組數）、
`tx_payload_tdata/tkeep/tvalid/tready/tlast/tuser`。來源埠固定 9100。

### 4.2 封包格式（UDP 負載，所有欄位 little-endian）

請求和回覆共用 24 位元組的頭：

| 位移 | 欄位 | 說明 |
|---|---|---|
| 0 | `magic` u16 | `0xA7E1` |
| 2 | `version` u8 | `1` |
| 3 | `opcode` u8 | 請求：1 READ、2 WRITE、3 INFO、4 PING；回覆 = 請求 opcode \| 0x80 |
| 4 | `seq` u32 | 主機給定，回覆原樣帶回 |
| 8 | `addr` u32 | AXI4-Lite 位元組地址（v1 地址表），必須 4 對齊 |
| 12 | `count` u16 | 32 bit 字數。請求：1..MAX_WORDS（READ/WRITE），INFO/PING 為 0。回覆：實際完成的字數 |
| 14 | `flags` u16 | bit0 `NOINC`：每個字都用同一地址；其餘位必須為 0 |
| 16 | `status` u16 | 請求填 0。回覆：0 OK、1 AXI_ERR（SLVERR/DECERR）、2 BAD_REQ、3 AXI_TIMEOUT、4 BUSY |
| 18 | `err_index` u16 | 回覆：出錯的字索引（status=1/3 時有效），否則 0 |
| 20 | `reserved` u32 | 0 |
| 24 | `data` | WRITE 請求：count 個字；READ 回覆：count（實際完成數）個字；INFO 回覆：見下 |

- UDP 負載長度必須等於 `24 + 4*count`（WRITE 請求）或 `24`（READ/INFO/PING 請求）；不符 → BAD_REQ。
- magic 或 version 錯、長度 < 24 → 直接丟棄並計數（不回覆）。
- `MAX_WORDS` 參數，預設 2048（8216 位元組，需巨型幀）；主機依 MTU 自選每包字數（1500 MTU 用 256）。
- 執行：逐字發 AXI4-Lite 單筆交易。第一個錯誤就停，`count` = 已完成字數，`err_index` = 出錯索引。
  單筆交易超過 4096 個 host_clk 週期無回應 → AXI_TIMEOUT（保險；awg_control 正常都會回應）。
- 去重：FPGA 記住最後一個**已執行**的 WRITE 的 `seq` 和回覆頭。再收到相同 seq 的 WRITE（主機重傳）時不再執行，只重送快取的回覆頭。
  READ/INFO/PING 一律重新執行（沒有副作用）。上電後去重狀態為空。
- 一次只處理一個請求；入口 FIFO 至少能放 4 個最大長度請求，滿了就整包丟棄並計數（主機會重傳）。
- INFO 回覆 `count` = 16，資料 16 個字：
  `[0]` `0x41574531`（"AWE1"）、`[1]` 協定版本 1、`[2]` MAX_WORDS、`[3]` BUILD_ID 參數、
  `[4]` rx_ok、`[5]` rx_bad_req、`[6]` rx_dropped（magic/版本錯、壞幀、FIFO 滿）、`[7]` tx_replies、
  `[8]` dup_writes、`[9]` axi_errors、`[10]` axi_timeouts、`[11]` axi_words、`[12..15]` 0。
  計數器 32 bit 飽和，不歸零。
- PING 回覆 `count` = 0，無資料。

### 4.3 主機側重傳

主機同時在途最多 W 個請求（預設 8；改控制暫存器 `0x90200008/0C/10` 時 W=1），
逾時 50 ms 重送同一 seq，最多 5 次。seq 每個新請求遞增，起始值隨機。

## 5. 任務分解（第 1 期）

| 任務 | 內容 | 歸屬檔案 | 依賴 |
|---|---|---|---|
| E1 | `awg_eth_bridge`（CDC + 命令引擎 + 計數器）、`axil_arb2`；xsim TB 接真的 v1 `awg_subsystem` 和 `adc_capture` | `rtl/eth/awg_eth_bridge*.sv`、`rtl/eth/axil_arb2.sv`、`sim/eth_bridge/`、`reports/E1/` | 本規格 |
| E2 | `awg_eth_core`（40G MAC 包裝 + 精簡 UDP 堆疊，只收 9100）；xsim TB 在 256 bit MAC 介面注入 ARP/UDP 幀 | `rtl/eth/awg_eth_core.v`、`rtl/eth/awg_udp_port.v`、`sim/eth_core/`、`reports/E2/` | 本規格 |
| E3 | Python 主機庫 + CLI + GUI 橋接（同 v1 檔案 IPC）+ FPGA 協定模擬器 + MATLAB 傳輸切換 | `tools/awg_eth/`、`matlab/AWGBridge.m`、`matlab/AWGScopeApp.m`、`matlab/test_*.m`、`reports/E3/` | 本規格 |
| D0 | 從 XSA 重建 BD（9.8/5 GS/s）+ 612.5 MHz 時序探測 | `scripts/bd/`、`scripts/d0/`、`rtl/d0/`、`constraints/d0/` | doc/01 |
| D1 | TX 子系統 `awg_tx`（URAM 14 bit） | `rtl/tx/`、`sim/tx/` | doc/01 |
| D2 | RX 子系統 `awg_rx`（BRAM 14 bit） | `rtl/rx/`、`sim/rx/` | doc/01 |
| D3 | `awg_control_v2` + 正式頂層整合（E1/E2/D1/D2）+ 約束 + 建置前審查 + 綜合/佈線 + bit/xsa | 頂層與腳本 | D0–D2、E1、E2 |
| F1 | 初始化韌體改 9.8 GS/s、ELF 重編（Claude 自己建置） | `software/` | D3 的 XSA |
| E5 | 上板（需使用者同意） | — | E3、D3、F1 |

E1/E2/E3/D0/D1/D2 檔案互不重疊，可並行。資料路徑規格見 `doc/01_DATAPATH_V2.md`（取代 v1 的 AXI 地址表，§8 的舊說法作廢）。

## 6. 資料路徑重做：DAC 9.8 GS/s、ADC 5 GS/s、14 bit（草案待確認）

官方資料核對（2026-11-11）：

- DS889 v1.14（2023-06-27）表 1/表 2：XCZU47DR = 8 × 14 bit RF-ADC（最高 5.0 GSPS）、8 × 14 bit RF-DAC（最高 **9.85** GSPS，註 2：「For 10GSPS RF-DAC operation, contact your local sales representative」）；
  10.0 GSPS（註 3：-2I）只列給 DFE 器件 ZU63/64/65/67DR。BRAM 1080（38.0 Mb）、URAM 80（22.5 Mb）、GTY 16（但本板封裝 fsve1156 只引出 8 個 GTY，D3A4 綜合確認；本設計用 4 個）、100G CMAC 2。
- DS926 v1.14：Gen3 -2E/-2I/-2LI 在 datapath mode 2/3/4，不用 clock forwarding 時 0.5–9.85 GS/s，用 clock forwarding 時 9.70 GS/s。
- 結論：本板（-2-i）的 DAC 規格上限是 9.85 GS/s。Vivado IP 允許填 10.0，但不在資料手冊保證範圍內，**採用 9.8 GS/s**。
- 官方 RFDC 驅動（embeddedsw `xrfdc.h/.c`）的 datapath mode：1 = DUC 0–Fs/2、2 = DUC 0–Fs/4（IMR 低通）、3 = DUC Fs/4–Fs/2（IMR 高通）、4 = 無 DUC 0–Fs/2（旁路）。
  IP 參數 `DAC_Mode00` 的編號比驅動少 1（IP 3 = 驅動 mode 4 旁路）。
  執行時可用 `XRfdc_SetDataPathMode/SetInterpolationFactor/SetFabRdVldWords` 切換；但 AXIS 時鐘是建置時決定的，執行時切換不會降低時鐘。

Vivado 2025.2 RFDC v2.6 在 `xczu47dr-fsve1156-2-i` 上的實測（`set_property` 驗證）：

| 設定 | 允許的每拍樣點數 | RFDC 介面時鐘 |
|---|---|---|
| DAC 10.0 GS/s，x1（DAC_Mode 3，無 DUC） | 只能 16 | 625 MHz |
| DAC 9.8 GS/s，x1 | 只能 16 | 612.5 MHz |
| DAC 9.8 GS/s，x2（DAC_Mode 1，實數） | 16 / 8 | 306.25 / 612.5 MHz |
| DAC 9.8 GS/s，x4（實數） | 16 / 8 / 4 | 153.1 / 306.25 / 612.5 MHz |
| DAC > 10.0 GS/s | 不允許（範圍 0.5–10.0） | — |
| ADC 5.0 GS/s，x1 | 9–12 | 最低 416.667 MHz（12 樣點/拍） |

IP `DAC_Mode00`=1（驅動 mode 2，IMR 低通，輸出頻帶 0–Fs/4）下插值不能選 x1；IP `DAC_Mode00`=3（旁路）只能 x1。
IQ 輸入（C2R）在單 slice 設定下被拒，尚未查清。

時鐘分層（x1 時 612.5 MHz 無法避免，只把它壓縮在最薄的邊界層）：

- 612.5 MHz：只放 TX 2:1 gearbox 讀側 + 一級暫存器 → RFDC s_axis。
- 416.667 MHz：只放 RFDC m_axis → 一級暫存器 → 2:1 寬度加倍寫側。
- 306.25 MHz（612.5/2，BUFGCE_DIV）：TX 播放器 + URAM。
- 208.333 MHz（416.667/2）：RX 打包 + BRAM 寫入。
- 312.5 MHz clk_eth、100 MHz host_clk：不變。

位寬：ZU47DR 的 RF-DAC/RF-ADC 解析度都是 14 bit（AXIS 用 16 bit 容器，MSB 對齊，低 2 bit 無效）。
v1 文件裡的「12-bit ADC」是誤讀：192 bit = 每拍 12 個樣點 × 16 bit。

## 7. RAM 優化（草案）

- TX：URAM，14 bit 緊密打包。306.25 MHz 下每通道每拍 32 樣點 × 14 = 448 bit → 7 塊 URAM 寬（504 bit），深 4096
  → **每通道 131072 點（9.8 GS/s 下 13.4 µs，v1 的 2 倍）**，8 通道 56/80 塊 URAM，TX 不用 BRAM（v1 用 256 塊 RAMB36）。
  URAM 在這裡是頻寬受限而非容量受限，所以深度翻倍是白送的。
- RX：BRAM，14 bit 打包。208.333 MHz 下每拍 24 樣點 × 14 = 336 bit。每通道 65536 點約 28 塊 RAMB36，8 通道約 224 塊
  （v1 約 264–352 塊，按 RTL 推算）。
- 光口 FIFO：v3 的 RX 128 KiB / TX 64 KiB 幀 FIFO 改小到 32 KiB 級（本工程不需要深緩衝）。
- 選配：通道共用緩衝池（例如 1 通道 × 1M 點）。

## 8. 舊第 2 期草稿（已由 §6、§7 取代）

已知現況（按 RTL 推算）：TX 8 通道 × 65536 點 × 16 bit = 8 Mb 全在 BRAM；RX 8 × 65520 × 16 bit 容器 = 8 Mb。
URAM（80 塊、22.5 Mb）幾乎沒用。候選手段：

1. TX/RX 緩衝搬到 URAM，釋放 BRAM。
2. ADC 12 bit 緊密打包（省 25%）。
3. 通道共用緩衝池：每通道長度可配置（例如 1 通道長或 8 通道短）。
4. 加 256 bit 直寫/直讀通道，取代 AXI4-Lite 的資料面。
