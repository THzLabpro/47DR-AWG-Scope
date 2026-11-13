# 資料路徑 v2：DAC 9.8 GS/s ×1、ADC 5 GS/s ×1、14 bit 打包（凍結，2026-11-11）

使用者確認：第一版只做 1X（DAC 旁路，0–Fs/2 全頻帶），插值以後另做建置版本。
其餘按 Claude 建議的預設值；變更需使用者同意。依據見 `00_ETH_PLAN.md` §6。

## 1. 凍結參數

| 項目 | 值 |
|---|---|
| DAC | 8 通道（tile 0–3 的 slice 0、2，與 v1 相同），9.8 GS/s，IP `DAC_Mode`=3（驅動 mode 4 旁路），插值 x1，mixer bypass，`DAC_Data_Width`=16，實數 |
| ADC | 8 通道（與 v1 相同），5.0 GS/s，抽取 x1，mixer bypass，`ADC_Data_Width`=12，實數 |
| RF PLL 參考 | 200 MHz（LMK04828 現有 `lmk04828_init_data_200`，不改） |
| SYSREF | 416.67 kHz（LMK VCO 2400 MHz ÷ 5760，不改） |
| 樣點格式 | 14 bit 有效，AXIS 16 bit 容器 MSB 對齊；主機線上一律 int16（低 2 bit 寫入時丟棄、讀出時為 0） |

## 2. 時鐘域

| 名稱 | 頻率 | 來源 | 內容（只能放這些） |
|---|---|---|---|
| `dac_clk` | 612.5 MHz | MMCM（照 v1 做法，由 RFDC clk_dac 或 PL 參考產生） | RFDC s_axis；TX 2:1 寬度轉換讀側；一級暫存器 |
| `tx_clk` | 306.25 MHz | `dac_clk` 經 BUFGCE_DIV ÷2（同源同相） | TX URAM、播放器、寫入打包、CRC |
| `adc_clk` | 416.667 MHz | MMCM（LMK PL_CLK 200 MHz，照 v1） | RFDC m_axis；一級暫存器；1:2 寬度加倍寫側 |
| `rx_clk` | 208.333 MHz | `adc_clk` 經 BUFGCE_DIV ÷2 | RX 打包、BRAM 寫入 |
| `host_clk` | 100 MHz | PS pl_clk0 | AXI4-Lite、控制、BRAM 讀出 |
| `clk_eth` | 312.5 MHz | 40G MAC | 光口 |

`dac_clk` 與 `adc_clk` 域內不得有組合邏輯深度 > 1 LUT 的路徑（寬度轉換的多工除外，須用暫存器選擇信號）。

## 3. TX 子系統 `awg_tx`

- 8 通道；每通道緩衝 4096 字 × 448 bit（32 樣點 × 14 bit），以 7 塊 URAM288（各 72 bit 寬、4096 深）實作，共 56 塊。每通道 131072 點。
- 播放：長度 `length_words`（1..4096，單位 32 點），遮罩 `mask`；所有啟用通道同一拍起播、無縫循環；停止時輸出 0。
- 寫入：host 側每次給 32 bit（兩個 int16：`[15:0]` 先、`[31:16]` 後），awg_tx 截成 14 bit，每湊滿 16 次（32 樣點）寫一個 URAM 字；寫指標自動遞增。只能在停止狀態寫入。
- CRC：命令觸發後，在 `tx_clk` 域讀 URAM 指定通道的前 `length_words` 字，計算 CRC-32（IEEE 802.3，反射，初值 0xFFFFFFFF，最後取反），
  輸入位元組序列 = 每個樣點還原成 int16（14 bit 左移 2，低 2 bit 為 0）的 little-endian 2 位元組，按時間順序。主機用相同規則計算。
- 起播事件 `tx_start_event`：第一個有效樣點送進 RFDC 的那一拍，在 `dac_clk` 域產生，經 toggle 同步給 RX。
- 播放位置 `tx_play_word`（目前讀的 URAM 字索引）：awg_tx 輸出的 `tx_clk` 域暫存器（二進位，迴繞於 `length_words`）。
  跨到 RX（2026-11-11 D2 審查後定案）：awg_rx 增加輸入 `tx_clk`，內部用 `xpm_cdc_handshake`（src=`tx_clk`、dest=`rx_clk`）
  在 tx_clk 側每當握手空閒就送出當下的 `tx_play_word`，rx_clk 側保留最近一次收到的值。保證多位元一致；
  數值比實際播放位置落後一個握手週期（D3A 實測 2–17 字），屬於「粗略」定位，精度要求 ≤ 24 字。
  需要精確對齊時用 `trig_mode`=1（起播同步）。

host_clk 側介面（awg_tx 提供，CDC 由 awg_tx 內部負責）：

| 信號 | 方向 | 說明 |
|---|---|---|
| `h_wr_ch[2:0]`、`h_wr_rewind` | in | rewind 單拍脈衝：該通道寫指標歸零、打包暫存清空 |
| `h_wr_data[31:0]`、`h_wr_valid`、`h_wr_ready` | in/in/out | 寫資料流（有背壓） |
| `h_wr_ptr[17:0]` | out | 已寫入的樣點數（同步回 host 域，可延遲） |
| `h_crc_start`、`h_crc_ch[2:0]` | in | 單拍脈衝 |
| `h_crc_busy`、`h_crc_value[31:0]` | out | |
| `h_start`、`h_stop`、`h_clear_fault` | in | 單拍脈衝 |
| `h_length_words[12:0]`、`h_mask[7:0]` | in | 停止時才可改；awg_tx 在 start 時取樣 |
| `h_running`、`h_started`、`h_faults[7:0]`、`h_wrap_count[31:0]`、`h_locked` | out | `h_locked`=執行中或命令處理中，此時寫入應被控制層拒絕 |
| `h_start_rejected` | out | 最近一次 start 因某個啟用通道已寫樣點數 < length×32 而被拒（保持到下一次 start） |

awg_tx 內部為每通道記錄已寫字數（rewind 歸零），start 時檢查。

## 4. RX 子系統 `awg_rx`

- 8 通道；RFDC 每拍 12 樣點（192 bit）@416.667 MHz → 每 2 拍 24 樣點 × 14 = 336 bit @208.333 MHz 寫入 BRAM。
- 深度：每通道 2730 字 × 336 bit = 65520 點（與 v1 相同上限）。擷取長度 `cap_words`（1..2730，單位 24 點）。
- 觸發：`trig_mode`=0 手動（arm 後下一個 24 點邊界開始）；=1 DAC 起播同步（arm 後等 `tx_start_event`）。
  `dac_clk`→`adc_clk` 用 toggle 同步，延遲抖動 ≤ 1 個 `rx_clk` 拍（24 點）；精確對齊由主機做相關運算校準。
- 開始擷取時記錄 `cap_tx_word`（取樣 `tx_play_word`）。
- 讀出：host_clk 域 BRAM 讀口，按 (通道, 樣點對索引) 讀，回傳兩個 int16（MSB 對齊、低 2 bit 為 0；`[15:0]` 是較早樣點）。

host_clk 側介面：

| 信號 | 方向 | 說明 |
|---|---|---|
| `h_arm`、`h_trig_mode`、`h_cap_words[11:0]` | in | arm 單拍；其他在 arm 時取樣 |
| `h_abort` | in | 單拍：取消 armed/擷取，回到閒置（2026-11-11 D3A2 審查後新增） |
| `h_armed` | out | 已 arm、等待觸發 |
| `h_busy`、`h_done`、`h_captured_samples[16:0]`、`h_cap_tx_word[11:0]` | out | |
| `h_rd_ch[2:0]`、`h_rd_pair[14:0]`、`h_rd_req` | in | 單拍請求 |
| `h_rd_data[31:0]`、`h_rd_valid` | out | 固定延遲 ≤ 4 拍 |

## 5. 控制暫存器 v2（`awg_control_v2`，AXI4-Lite，基址 0x9020_0000）

v1 的 RAM 直接地址窗（0x9000_0000、0x9100_0000）取消，改用資料埠。

| 偏移 | 名稱 | 存取 | 說明 |
|---|---|---|---|
| 0x00 | ID | R | `0x41574732`（"AWG2"） |
| 0x04 | STATUS | R | bit0 running、bit1 cmd_busy（awg_tx 正在處理 start/stop/CRC 命令，即 `h_locked && !h_running` 或 `h_crc_busy`）、bit2 ps_ready、bit3 fault、bit5:4 last_cmd_result（0 OK、1 拒絕、2 fault）、bit6 cap_busy、bit7 cap_done、bit8 crc_busy |
| 0x08 | COMMAND | W | 1 stop、2 start、4 clear_fault、8 arm capture、16 compute TX CRC（用 TX_WR_CH 的通道、TX_LENGTH 的長度）、32 abort capture（取消等待觸發或進行中的擷取，awg_rx 回到閒置，done 清 0；閒置時也接受）。非法或狀態不允許 → SLVERR |
| 0x0C | TX_LENGTH | RW | 1..4096（32 點單位）；執行中寫 → SLVERR |
| 0x10 | TX_MASK | RW | 8 bit；執行中寫 → SLVERR |
| 0x14 | DAC_FS_KSPS | R | 9800000 |
| 0x18 | ADC_FS_KSPS | R | 5000000 |
| 0x1C | FAULTS | R | 每通道 underflow fault |
| 0x20 | ABI | R | `0x00030001` |
| 0x24 | TX_MAX_WORDS / CAP_MAX_WORDS | R | `[15:0]`=4096、`[31:16]`=2730 |
| 0x28 | CAP_STATUS | R | bit0 busy、bit1 done、bit2 armed（已 arm、尚未觸發；armed=1 時 busy 也為 1） |
| 0x2C | CAP_SAMPLES | R | 已擷取樣點數 |
| 0x30 | TX_WR_CH | RW | 寫入 = 選通道並 rewind（指標歸零）；執行中寫 → SLVERR |
| 0x34 | TX_WR_PTR | R | 目前通道已寫樣點數 |
| 0x38 | TX_WR_DATA | W | 兩個 int16；配合協定 NOINC 連續寫；執行中寫 → SLVERR；背壓時 AXI 寫回應延遲（不得丟資料） |
| 0x3C | TX_CRC | R | 最後一次 CRC 結果 |
| 0x40 | CAP_RD_CH | RW | 寫入 = 選通道並把讀指標歸零 |
| 0x44 | CAP_RD_PTR | RW | 樣點對索引；可寫入以跳到任意位置 |
| 0x48 | CAP_RD_DATA | R | 兩個 int16；每讀一次指標 +1；配合協定 NOINC 連續讀；擷取 busy 時讀、指標 ≥ 32760 時讀、或 awg_rx 15 拍內未回應 → 立即 SLVERR（不得卡住匯流排；2026-11-12 E5 上板發現越界會鎖死，D3C 修正） |
| 0x4C | CAP_CTRL | RW | bit0 trig_mode；`[27:16]` cap_words（1..2730）；擷取中寫 → SLVERR |
| 0x50 | CAP_TX_WORD | R | 擷取開始時的 TX 播放字索引 |
| 0x54 | BUILD_ID | R | 參數 |
| 其他 | — | — | 讀寫皆 SLVERR |

start 檢查（沿用 v1 語意）：ps_ready=1、未執行、mask≠0、無 fault，且每個啟用通道 `TX_WR_PTR` ≥ `TX_LENGTH×32`（否則 SLVERR，避免播放未寫入的資料）。

## 6. 主機端流程（E3 依此實作）

1. load：stop → clear → 對每個通道：寫 TX_WR_CH → NOINC 寫 TX_WR_DATA（n/2 個字）→ 寫 TX_LENGTH、COMMAND=16 → 輪詢 crc_busy → 比對 TX_CRC 與主機計算值。最後寫 TX_MASK。
2. capture：寫 CAP_CTRL → COMMAND=8（trig_mode=1 時再 start）→ 輪詢 CAP_STATUS done → 每通道寫 CAP_RD_CH → NOINC 讀 CAP_RD_DATA。
3. 波形長度：32..131072 點且為 32 的倍數；擷取長度：24..65520 點且為 24 的倍數。
