# E1_BRIDGE — UDP 命令引擎 + AXI4-Lite master + 雙 master 仲裁

先讀 `AGENTS.md`、`doc/00_ETH_PLAN.md`（特別是 §2、§4，凍結）。

## 歸屬檔案（只能寫這些）

- `rtl/eth/awg_eth_bridge.sv`（頂層）及必要的子模組 `rtl/eth/awg_eth_bridge_*.sv`
- `rtl/eth/axil_arb2.sv`
- `sim/eth_bridge/**`（TB、向量、執行腳本、wcfg）
- `build/E1/**`、`reports/E1/**`

## 要做的

1. `awg_eth_bridge`
   - eth 側（`clk_eth`、`rst_eth` 同步高有效）：plan §4.1 的 RX/TX UDP app 介面，名稱照抄。
   - host 側（`host_clk`、`host_resetn` 同步低有效）：32 bit AXI4-Lite master（AW/W/B/AR/R 全部信號，`awprot/arprot` 可省略）。
   - 參數：`MAX_WORDS`（預設 2048）、`BUILD_ID`（32 bit）、`AXI_TIMEOUT_CYCLES`（預設 4096）。
   - CDC 用本工程 `rtl/eth/vendor/verilog-ethernet/lib/axis/rtl/axis_async_fifo.v`（唯讀，直接例化）或 XPM；
     UDP 頭欄位（src_ip、src_port、length）跟負載一起過 CDC（例如當成負載前面的一拍，或並行的小 FIFO），不得用多 bit 直接同步。
   - 命令引擎在 host_clk 域；完整實作 plan §4.2：格式檢查、READ/WRITE/INFO/PING、NOINC、逐字執行、第一個錯誤即停、
     超時、WRITE 去重、計數器（32 bit 飽和）、入口 FIFO 滿時整包丟棄。
   - 只發 AXI4-Lite 單筆交易，同時只有一筆在途；`wstrb` 全 1。
   - 回覆的 `tx_dst_ip/port` = 請求的 src；`tx_length` = 24 + 4×count。
   - 不得把未完成的 READ 資料先送出再改 status：回覆頭必須反映最終 count/status（可先把讀回資料暫存在 host 側緩衝，深度 MAX_WORDS）。
2. `axil_arb2`：兩個 AXI4-Lite slave 埠（s0 = JTAG，s1 = Ethernet）→ 一個 master 埠。
   一次只放行一筆完整交易（讀或寫），輪詢公平；不得讓同一 master 的 AW 和 W 被拆給不同交易。
3. TB（xsim，SystemVerilog）
   - DUT 鏈：TB 的 UDP app 驅動 → `awg_eth_bridge` → `axil_arb2`（s0 由 TB 的簡易 JTAG master 同時發隨機讀寫）→ 本工程 `rtl/` 下的 v1
     `awg_subsystem` + `adc_capture`（照 `rtl/adaloop_top.v` 的接法；RFDC 用 TB 模型：DAC `dac_ready`=1，ADC 每拍給可預測的遞增樣點）。
   - 時鐘：clk_eth 312.5 MHz、host_clk 100 MHz、sample_clk 562.5 MHz、ram_clk = sample_clk/4（照 rtl/adaloop_top.v）、adc_clk 416.667 MHz、adc ram clk = adc_clk/4。`ps_config_done`=1。
   - 場景（每個都要自動判 PASS/FAIL）：
     - S1 PING、INFO（檢查固定字和 MAX_WORDS）。
     - S2 WRITE 波形 RAM：CH0 和 CH7 各寫 2048 字（分 8 包、每包 256 字），再 READ 回來逐字比對。
     - S3 一包 2048 字的 WRITE + READ（巨型）。
     - S4 暫存器：寫長度 `0x9020000C`、遮罩 `0x90200010`，讀回；寫非法值得到 status=1、err_index 正確。
     - S5 命令：start（`0x90200008`=2）、讀狀態看到 running、執行中寫 RAM 得到 AXI_ERR、stop。
     - S6 擷取：命令 8 觸發 ADC 擷取，輪詢 `0x90200028` 直到 done，READ `0x91000000` 起 CH0 的前 96 字和 CH3 的前 96 字，按 v1 打包格式（每 768 bit entry 24 字）比對 TB 注入的樣點。
     - S7 去重：同一 seq 的 WRITE 送兩次（第二次換不同資料），確認 RAM 是第一次的資料、dup_writes 加 1、兩次回覆頭相同。
     - S8 壞請求：magic 錯（無回覆、rx_dropped+1）、長度和 count 不符（BAD_REQ）、count > MAX_WORDS（BAD_REQ）、flags 非法位（BAD_REQ）、地址不對齊（BAD_REQ）、tuser=1 的包（丟棄）。
     - S9 入口 FIFO 背壓：連續塞 16 個最大 WRITE 不等回覆，確認不死鎖、被丟的包計入 rx_dropped、收到的回覆 seq 各不相同且每個成功回覆的資料確實寫入。
     - S10 吞吐：連續 64 包 × 256 字 WRITE（TB 不限速），量測 host_clk 週期數，報告 MB/s（以 100 MHz 計）。驗收 ≥ 80 MB/s；不足就報告瓶頸。
     - S11 仲裁：S2 期間 JTAG master 同時隨機讀寫暫存器 `0x90200000/04/0C`，兩邊結果都正確、無死鎖。
   - 提供 `sim/eth_bridge/run.ps1`（一鍵 xvlog/xelab/xsim），以及能在 Vivado GUI 看波形的 wcfg。
4. 另做 `axil_arb2` 和 `awg_eth_bridge` 各自的 OOC 綜合（`xczu47dr-fsve1156-2-i`，host_clk 100 MHz、clk_eth 312.5 MHz），報告 LUT/FF/BRAM/URAM 和 WNS。這是短任務，不做整片。

## 驗收（固定）

1. S1–S11 全 PASS，日誌在 `reports/E1/`。
2. S10 吞吐 ≥ 80 MB/s（或寫明瓶頸並停在 NEEDS_PARENT_JUDGMENT）。
3. 兩個 OOC 綜合 0 error，WNS ≥ 0，CDC 有正確約束（axis_async_fifo 的約束方式寫在報告裡）。
4. `xvlog` 無 error；報告列出所有 critical warning。
