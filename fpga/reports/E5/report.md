# E5 — 上板測試（D3B bit + F1 ELF）

日期：2026-11-12。使用者已同意上板。板卡 JTAG 15051A、PS UART COM8；PC XL710「以太网 4」= 192.168.42.10，40 Gbps。

結論：**核心功能在板上全部可用**：初始化、40GbE 控制、波形下載與 CRC、循環播放、起播觸發擷取、回傳。另外發現 3 個需要重新建置才能修的問題和 1 個環境干擾，見文末。

## 1. 初始化（`scripts/program.tcl -package build/F1/package`）

- 做了 2 次，都成功（`init_log1.txt`、`init_log2.bin`）。
- COM8 被其他程式占用，所以改用 `scripts/read_init_trace.tcl` 經 JTAG 讀 DDR 裡的 `awg_init_log`。
- 結果：`INIT_STAGE_FULL=99`、`CONFIG_DONE=1`。
- LMK：PLL2 鎖定，SYSREF 416.667 kHz。
- RFDC PLL 回讀：

  | 轉換器 | 參考 | 倍頻／除頻 | 取樣率 | 鎖定 |
  |---|---|---|---|---|
  | DAC tile 2 | 200 MHz | ×49 ÷1 | 9.8 GS/s | 是 |
  | ADC tile 1 | 200 MHz | ×50 ÷2 | 5.0 GS/s | 是 |

- MTS：DAC 4 個 tile 延遲 288 T1、偏移 0；ADC 延遲 112 T1、偏移 8/8/0/0。
- 印出 `AWG READY: DAC=9800000000 ... data clocks=612500000/416666667Hz`。

## 2. 40GbE 控制路徑

- `ping`：OK。ARP 解析到 `02:47:41:00:00:02`。
- `info`：protocol 1、build `0xD3A32026`。
- 暫存器：`ID=0x41574732`、`DAC_FS_KSPS=9800000`、`ADC_FS_KSPS=5000000`、`ABI=0x00030001`、`ps_ready=1`。
- **最大幀長 1518 B**（問題 A）：
  - 實測 UDP 負載 1424 B（350 字）能通過，1496 B 以上 FPGA 就不收；`rx_ok`、`rx_dropped` 都不增加。
  - 原因：`rtl/eth/v3_qsfp2/optical_port2_exdes.v:577` 寫死 `ctl_rx_max_packet_len_0 = 15'd1518`。
  - 規格 §4 與 INFO 的 `max_words=2048`（8 KB）要求 jumbo frame，目前做不到。

## 3. 波形下載、播放、擷取（`scripts/e5/e5_board_test.py`，結果在 `run1/result.json`）

- 波形：8 通道 × 131072 點，每通道一個單音，都是整數週期，所以循環無縫。CH0 是 50.020 MHz，……，CH7 是 898.0 MHz。幅度 0.5 FS。
- 下載：8 通道逐一驗 CRC，**全部吻合**。2 MiB 花 0.82 s（2.56 MB/s，含 CRC 命令），使用 256 字/包。
- 起播觸發擷取：8 通道 × 65520 點全部讀回，`cap_tx_word=0`，`fault=0`。
- 吞吐（`cli bench`）：

  | 字/包 | window | 寫 MB/s | 讀 MB/s |
  |---|---|---|---|
  | 256 | 8 | 4.28 | 4.68 |
  | 350 | 8 | 4.65 | 6.14 |
  | 350 | 128 | 5.86 | 6.31 |

  - window 沒有影響，因為 NOINC 資料埠在 client 裡是停等式（window=1，重送安全考量）。
  - 吞吐約等於「每次往返送一包」，要提速就要加大封包，也就是問題 A。

## 4. 類比回環

- 回環通道是 **DAC CH0 → ADC CH0**：ADC0 出現 50.02 MHz、約 7100 LSB（−1.2 dBFS）的單音；ADC1–7 只有雜訊（rms 22–24 LSB）。
  - v1 的記錄是 CH2 → CH2，接線可能改過，**需要使用者確認目前接法**。
- 頻率：最佳擬合頻偏 0 Hz，DAC/ADC 時鐘同調。
- 完整性：
  - 整段擷取分成 27 個窗，每窗相位都是 1.816 rad、幅度 7112–7116 LSB。**沒有掉點、重複點或前後半字對調**。
  - 殘差依位置（mod 24）分布均勻，沒有固定樣點位置的誤差。
- 雜訊：突發之間的殘差 23–28 LSB，接近空閒通道的雜訊底，SNR 約 46 dB。
- 整體 SINAD 36.8–39.8 dB（4 次，`repeat/summary.json`），被 CH0 上的 27–39 MHz 突發拉低。
  - 突發每次位置都不同。
  - 停掉 DAC 時照樣出現（`dac_off/summary.json`：CH0 block rms 最高 855 LSB，CH1 37 LSB）。
  - 所以是 CH0 回環線纜或輸入端拾取的外部干擾，**不是 FPGA 資料路徑的問題**。
- 起播觸發對齊：4 次 onset 分別是 468/470/478/480 點，run1 是 486 點，相位變化與此一致。
  - 抖動 ≤ 1 個 RX 字（24 點、4.8 ns），來自 dac_clk → rx_clk 起播事件同步的固有不確定度。
  - doc/01 寫的「精確對齊」實際精度是一個 RX 字。

## 5. 問題與處理

| # | 問題 | 影響 | 處理 |
|---|---|---|---|
| A | MAC `ctl_rx_max_packet_len=1518`，不收 jumbo | 每包最多 350 字，吞吐 4–6 MB/s | 需要改 RTL 並重新建置（改成 9600），預期每包 2048 字，吞吐約 5–6 倍 |
| B | 寫 `CAP_RD_CH` 不會把讀指標歸零（`awg_control_v2.sv:245`；doc/01 §5 規定要歸零） | 讀完 CH0 後讀 CH1 從 32760 開始 | 已在主機端繞過：`awg.py`、`cli.py` 寫完 CAP_RD_CH 後寫 `CAP_RD_PTR=0`，pytest 13/13。RTL 待修 |
| C | 讀指標越界（≥32760）時讀 `CAP_RD_DATA`，awg_rx 不回應，控制器永遠停在 `ST_RD_DATA` | AXI 匯流排鎖死，所有暫存器讀寫逾時，只能重新初始化（第一次 run1 就是這樣：`axi_timeouts=2`） | RTL 待修：越界應回 SLVERR，而且 awg_rx 對每個請求都要回 valid |
| D | CH0 回環 27–39 MHz 外部干擾突發 | SINAD 37–40 dB | 檢查線纜和屏蔽，與 FPGA 無關 |

另外：D3B 時序最緊的 `adc_pair_valid_q` 跨域（+5 ps）在板上沒有觀察到錯誤：相位連續、殘差沒有 24 點週期性。但這只是一次建置的結果，建議與 A–C 一起修。

## 6. 硬體狀態

- 板子保持初始化完成的狀態，TX 已停止。
- hw_server（tcp:3121）仍在執行，方便後續測試。
- 沒有改板上設定或 LMK 預設值，以外的東西都沒動。

## 檔案

- `init_log1.txt`：完整開機訊息。
- `program*.log`、`eth_basic.log`、`run1.log`、`repeat.log`、`dac_off.log`。
- `run1/result.json`、`repeat/summary.json`、`dac_off/summary.json`。
- 測試腳本：`scripts/e5/e5_board_test.py`、`e5_cap_read_probe.py`、`e5_repeat_capture.py`。
- 波形 hex 與擷取 CSV 留在 reports/E5 本地，不入庫（重跑腳本即可重新產生）。
