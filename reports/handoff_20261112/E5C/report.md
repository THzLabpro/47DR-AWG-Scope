# E5C — D3C 上板驗證

日期：2026-11-12，使用者同意上板。套件 `build/F1/package`：D3C bit `A294A0D8…`，ELF 從 D3C XSA 重建。

結論：**PASS**。D3C 的三項修正在板上全部驗證通過，功能與 E5 相同，資料埠吞吐約為原本的 3 倍。

## 初始化

- `INIT_STAGE=99`、`CONFIG_DONE=1`，詳見 `init_log1.txt`。
- PLL：DAC tile 2 為 200 MHz × 49 = 9.8 GS/s，ADC tile 1 為 5.0 GS/s，都已鎖定。
- MTS 完成：DAC 延遲 272 T1、ADC 116 T1，偏移都是 0。E5 時是 288 和 112，每次開機略有不同，屬正常。
- 印出 `AWG READY`。

## 修正驗證（`scripts/e5/e5c_fix_probe.py`，`fix_probe.json`：14 PASS / 0 FAIL）

| 項目 | 結果 |
|---|---|
| BUILD_ID | `0xD3C02026` |
| A jumbo 寫入 | 每包 256、350、368、512、1024、2048 字都被接受（UDP 負載最大 8216 B）。E5 時 368 字以上全部被丟棄 |
| A jumbo 讀取 | 一包 2048 字讀回成功 |
| B 讀指標歸零 | 先寫 `CAP_RD_PTR=123`，再寫 `CAP_RD_CH`，讀回 `CAP_RD_PTR=0` |
| C 越界讀取 | 指標 32759 讀一次後變成 32760；再讀回 AXI error（status=1）；之後讀 ID 正常，`axi_timeouts=0` |
| 取消擷取 | arm 後 `CAP_STATUS=0x5`，COMMAND=32 之後變成 0 |

執行過程中兩次 FAIL 都是測試腳本的問題，已修正後重跑：
- `TX_WR_PTR` 以 32 點為單位，350 字 = 700 點會回報 672。
- 上一輪把讀指標留在 32760，下一輪一開始的讀取就被正確擋下。

## 功能與效能

- 下載（`run1/result.json`）：8 通道 × 131072 點，CRC 全部吻合。每包 2048 字，耗時 0.65 s，其中包含主機解析 hex 檔和 CRC 指令。
- 起播觸發擷取：8 通道 × 65520 點全部讀回，耗時 0.22 s。
- CH0 回環：50.02 MHz，幅度 7149 LSB，onset 487 點。SINAD 39.2 dB、SFDR 49.1 dB，和 E5 相同；限制來源仍是 CH0 線纜上的外部干擾。
- 資料埠吞吐（`cli bench`，NOINC 停等式）：

| 字/包 | 寫 MB/s | 讀 MB/s |
|---|---|---|
| 256 | 3.83 | 3.16 |
| 1024 | 7.85 | 8.17 |
| 2048 | **11.38** | **12.45** |

- 每包時間分析：
  - 小包往返 249 µs，這是 Windows 上 Python UDP 的延遲；
  - 2048 字的包每包 705 µs；FPGA 端只佔約 180 µs（系統模擬裡 bridge 寫入約 46 MB/s）。
  - 剩下的瓶頸在主機端：Python 封包處理，以及 NOINC 只能停等。
- 再往上提速的方向（主機端，不需要改 FPGA）：
  - NOINC 改成管線化，bridge 依序處理，並靠 seq 去重；
  - 或改用 C/numpy 打包。

## 其他

- `axi_errors=4`，全部來自刻意的越界測試；`axi_timeouts=0`、`rx_dropped=0`、`rx_bad_req=0`。
- 板子目前保持初始化完成的狀態，TX 已停止。hw_server（tcp:3121）仍在執行。
