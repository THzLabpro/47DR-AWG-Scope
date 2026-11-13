# E7 — 上板測試 V1.2 exe「一鍵下載 bit 並初始化」（2026-11-12）

使用者要求上板測試。測試對象是交接包裡的 exe：`05_host_app\AWG47DR_V1\AWG47DR_V1.exe --program --yes`，它與選單「设备 → 下载 bit 并初始化」走同一個函式，只是不跳確認框。
- 固件：exe 旁邊的 `firmware\`（D3C bit + F1 elf）。
- 本機：xsct 自動找到 `D:\AMDDesignTools\2025.2\Vitis\bin\xsct.bat`。測試前沒有 hw_server 在跑，由 xsct 自動啟動。
- JTAG：FTDI 15051。
- 網卡：以太网 4 192.168.42.10，40 Gbps。

## 結果：3/3 成功

| 次 | xsct（hw_server→psu_init→LMK→fpga→放行） | 等 ps_ready | 總時間 | 燒錄後 running/mask | BUILD_ID | CH0 回環 |
|---|---|---|---|---|---|---|
| 1 | 24 s | 4 s | 28 s | 0/0（燒錄前沒有設好標記，見下） | 0xD3C02026 | 99.96483 MHz，−14.1 dBFS |
| 2 | 24 s | 4 s | 27 s | **0/0**（燒錄前是 1/255） | 0xD3C02026 | 99.96483 MHz，−13.7 dBFS |
| 3 | 23 s | 2 s | 25 s | **0/0**（燒錄前是 1/1） | 0xD3C02026 | 99.96483 MHz，−13.7 dBFS |

- 第 2、3 次燒錄前先下載波形並 Run，留下標記。燒錄後標記都被清掉，證明板子確實重設並重新燒錄，不只是重新連線。
- 第 1 次燒錄後做了完整功能驗證：
  - 8 通道 × 131072 點下載含 CRC：0.11 s，沒有 fallback；
  - 起播同步擷取 8 通道 × 65520 點；ADC0 回環 99.96483 MHz，SFDR 47.9 dBc；
  - ADC1–7 沒有接線，只有雜訊，符合預期。
- 完整日誌見 `awg_gui_20261112.log`（上位機自動寫入 `%APPDATA%\awg_gui_v1\logs\`）。

## 一次無法重現的逾時

第 1 次燒錄**之前**，在跑了很久的 D3C 板上設標記時：`load_words` 先 stop，隨後讀 TX_LENGTH，5 次重試（0.2 s）都沒有回覆。

- 同一個連線前一步的讀取都正常。
- 燒錄後用同樣的序列連跑 20 次，0 失敗；第 2、3 次燒錄前的標記也都設成功。
- 原因不明，也無法重現，先記錄。上位機遇到這種情況會顯示逾時錯誤，重試或重新燒錄都能恢復。

## 本次修改（v1-release）

- 上位機日誌同時寫入 `%APPDATA%\awg_gui_v1\logs\awg_gui_YYYYMMDD.log`，方便現場除錯。
- 命令列 `--program`：啟動後立即一鍵燒錄，會跳確認框；加 `--yes` 則不跳。
- 測試：36 項 pytest 全過；exe 的 `--selftest` PASS。

## 換電腦可攜性（2026-11-12）

- 交接包內的建置／模擬腳本原本寫死了 `D:\AMDDesignTools\2025.2`，共 15 支。現在統一改用 `scripts/xilinx_tools.ps1` 自動尋找安裝目錄：
  - 依序找環境變數 `AWG_XILINX_ROOT`、`XILINX_VIVADO`、PATH，以及各磁碟的 `AMDDesignTools|Xilinx|AMD\<版本>`；
  - 優先選 2025.2；
  - 同時設定 `PROCESSOR_ARCHITECTURE`。
  - 15 支腳本在 PowerShell 5.1 和 7 都能解析。
- `build_fw.ps1` 的預設 XSA 從 D3B_IMPL（不在交接包裡）改成 D3C_IMPL。
- 交接包移除了 `build/F1/bsp`、`obj`、`package_d3b`（可重新產生）。原因是 BSP 的路徑太長，加上交接包根目錄後會超過 260 字元。現在最深的相對路徑是 193 字元，所以交接包根目錄必須 ≤ 66 字元。
- 模擬全新電腦：
  - 條件：交接包複製到 `E:\awg_relocate_test\...`，全新 `APPDATA`，PATH 只有系統目錄；
  - exe `--selftest` PASS；
  - Vivado 開啟工程，588/0 缺檔；
  - `sim\d3\run_control_tb.ps1`（PS 5.1）57/0；
  - **exe `--program --yes` 28 s 完成**，BUILD_ID D3C，CH0 回環 99.96483 MHz。
