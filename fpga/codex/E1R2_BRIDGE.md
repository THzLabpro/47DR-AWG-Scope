# E1R2_BRIDGE — 橋接器儲存結構重寫 + 未完成驗收（第二輪）

先讀 `AGENTS.md`、`doc/00_ETH_PLAN.md`（§4 凍結）、`codex/E1_BRIDGE.md`（原驗收清單 S1–S11 不變）、`reports/E1/report.md`。

## 背景（Claude 審查 E1 第一輪）

功能面 S1–S5、S7、S8、S10（126 MB/s）已通過，協定處理邏輯可保留。必須改的是**硬體結構**：

1. `packet_mem` 是 `reg [7:0] [0:8215]`，RX 每拍以 `tkeep` 迴圈做最多 8 個動態位址的位元組寫入，標頭解析又用 `pkt_u8/u16/u32` 對任意位移做組合讀 → Vivado 無法推導 RAM（`Synth 8-3391`）。
2. TX 端 `response_byte(offset)` 對 `response_mem` 做任意位元組位移的組合讀，同樣是巨型多工器，即使綜合過也不會有好時序。

## 歸屬檔案（只能寫這些）

- `rtl/eth/awg_eth_bridge.sv`、`rtl/eth/axil_arb2.sv`
- `sim/eth_bridge/**`
- `build/E1R2_BRIDGE/**`、`reports/E1R2_BRIDGE/**`
- 工程根目錄的 `xsim.dir` 不要用；xsim 一律在 `build/E1R2_BRIDGE/` 下以 `-work`/工作目錄隔離。

## 結構要求

1. **RX 儲存**：UDP 酬載第 0~2 拍（24 位元組標頭）直接鎖進標頭暫存器（magic/version/opcode/seq/addr/count/flags/reserved），不經 RAM。
   - 從第 3 拍起，每拍 64 bit 原樣寫入 `payload_mem[beat-3]`（寬 64、深 1024，單寫埠、同步讀，用 `(* ram_style = "block" *)` 或 `xpm_memory_sdpram`）。
   - 依據：§4.2 標頭恰好 24 位元組（8 的倍數），酬載字元天然 8 位元組對齊；`tkeep` 只在最後一拍可能不滿，用 `rx_length` 判斷長度，**不做位元組壓縮**。
   - 保留原有檢查：長度不一致、超長、壞 magic/版本 → BAD_REQ 或丟棄（行為與第一輪相同）。
2. **命令引擎**讀 `payload_mem` 時用循序位址 + 同步讀（1~2 拍延遲，用流水或預取吸收），每拍取一個 32 bit 字（64 bit 字的高/低半）。
3. **TX 儲存**：`response_mem` 改為 64 bit 寬同步讀 RAM（READ 結果每兩個字湊一拍寫入）；回覆標頭 3 拍由暫存器直接組出；酬載拍從 RAM 循序讀出，用小 skid buffer 吸收讀延遲與 `tready` 背壓。不准再有任意位移的位元組多工器。
4. 時脈域、CDC FIFO、去重、計數器、INFO/PING 內容維持不變（對外介面凍結）。

## 驗收（固定）

1. **全部** S1–S11 PASS（xsim 日誌在 `reports/E1R2_BRIDGE/`，逐項列出 PASS/FAIL 計數）。特別是：
   - S6：用已修正的樣點索引重跑，比對 CH0 與 CH3 各 96 字。
   - S9：照原清單完整檢查 —— `rx_dropped` 計數 = 實際被丟的包數、所有回覆 seq 互不相同、每個成功回覆的 WRITE 資料確實寫入（讀回比對）。
   - S11：JTAG 與 Ethernet 兩個 master 同時存取時結果正確、無死鎖。第一輪現象：Ethernet 寫完後 JTAG 寫 `0x9020000C` 逾時，當時 JTAG 側 `bvalid=1` 且 `rvalid=1`。**先判定是 TB driver 還是 `axil_arb2` 的問題**（寫在報告裡，附波形或訊號列印證據），再修正對應的一方；仲裁器必須符合 AXI4-Lite：AW/W 可任意先後到達、B/R 只回給發起的 master、一筆交易完成前不切換。
2. OOC 綜合 + 實現（`awg_eth_bridge` 與 `axil_arb2` 各一次，依序執行，不要並行）：
   - `clk_eth` 312.5 MHz、`host_clk` 100 MHz 下 WNS ≥ 0、WHS ≥ 0。
   - 報告 LUT/FF/RAMB36/RAMB18/URAM；bridge 期望 BRAM ≤ 8 塊 RAMB36 等效（含兩個 async FIFO）、URAM 0。
   - `report_cdc` 無未處理 Critical；跨域約束只用於 async FIFO 的格雷碼指標與 ASYNC_REG 同步器（`set_max_delay -datapath_only` / `set_bus_skew`），不准整組 `set_clock_groups` 蓋掉別的路徑。
3. S10 吞吐仍 ≥ 80 MB/s。
4. 同一失敗最多修 2 輪；仍失敗就停，報告 `NEEDS_PARENT_JUDGMENT`。
