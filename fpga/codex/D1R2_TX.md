# D1R2_TX — TX 時序收斂（第二輪）

先讀 `AGENTS.md`、`doc/01_DATAPATH_V2.md`（凍結）、`codex/D1_TX.md`（原驗收 T1–T6 不變）、`reports/D1/report.md`、`reports/D1/ooc_impl_timing.rpt`。

## 背景（Claude 審查 D1 第一輪）

功能正確：T1–T6 `PASS=26 FAIL=0`，RTL CRC `D49307A0` 與 `sim/tx/crc_ref.py`、`tools/awg_eth/tests/crc_ref.py` 三方一致（Claude 已交叉驗證 ch0/ch5 × 131072 點）。資源正確：URAM 56、BRAM 0。

時序失敗原因（OOC route 後）：

| 路徑 | WNS | 原因 |
|---|---|---|
| tx_clk 域內 `rd_fifo_bin` → LUTRAM → `pack_buf` | -2.19 ns，8 級（MUXF7/F8 + RAMD64E） | CDC FIFO 是 1024 深的分散式 LUTRAM 非同步讀，後面直接接動態索引的打包多工器 |
| host_clk → tx_clk | -4.41 ns | OOC XDC 沒有任何 CDC 約束，LUTRAM 寫時鐘到讀資料被當同步路徑 |
| tx_clk → host_clk `write_samples` → `write_samples_h1` | -1.06 ns | 多位元計數器直接兩級同步到 host 域（多位元直接同步本身也不安全） |
| dac_clk 域內 `dac_phase` 複本 → `dac_tdata` | -0.016 ns | 複本扇出仍大、走線 1.45 ns |
| URAM | — | `awg_tx_uram_block` 讀延遲 1 拍，沒用 OREG |
| `pack_buf` 等資料暫存器 | — | 接了 reset（`/R` 腳出現在最差路徑上） |

## 歸屬檔案

- `rtl/tx/**`、`sim/tx/**`
- `build/D1R2_TX/**`、`reports/D1R2_TX/**`
- xsim 只在 `build/D1R2_TX/` 下跑，不用工程根目錄的 `xsim.dir`。

## 要做的

1. **CDC FIFO**：換成 `xpm_fifo_async`（`FIFO_MEMORY_TYPE "block"`，`READ_MODE "fwft"` 或 std 加輸出暫存器，深度 ≥ 512），或 ≤ 64 深的 LUTRAM 並在讀出端加暫存器。讀出資料先打一拍才進打包邏輯。
2. **打包器**：改成移位暫存器式 —— 每接受一個 32 bit 主機字，把兩個 14 bit 樣點（28 bit）移入 448 bit 移位暫存器，計數滿 16 字就寫一列 URAM。不准用動態位置索引寫 `pack_buf`。若同時支援多通道寫入，仍只需一個移位暫存器（`h_wr_ch` 改變或 rewind 時重新開始，行為依 `doc/01` §5）。
3. **URAM**：讀延遲 ≥ 3（有 OREG，`READ_LATENCY` 對應的 always 區塊寫法要讓 Vivado 吸收進 URAM 的 OREG/流水暫存器；綜合後用 `report_utilization`/`report_ram_utilization` 證明 OREG 已用上）。播放端相應調整，`tx_play_word`、`tx_start_event` 與實際送出資料的對應關係要保持 `doc/01` 規定。
4. **tx_clk → dac_clk**：URAM 輸出到 612.5 MHz 選擇器前，在 tx_clk 加 ≥ 2 級無 reset、無其他扇出的流水。dac_clk 側 `dac_phase` 每份複本負載 ≤ 64，`dac_tdata` 前只有一級 LUT。
5. **Reset**：資料路徑暫存器（移位暫存器、URAM 讀出流水、`tx_word`、`dac_tdata`）不接 reset，只有控制、指標、狀態機接。
6. **tx→host 狀態**：`write_samples`、`wrap_count` 等多位元狀態改用格雷碼或 req/ack 握手（資料保持穩定直到 ack）跨到 host 域；單位元用 ASYNC_REG 兩級同步。
7. **OOC XDC**（放在 `sim/tx/` 下，腳本引用）：
   - 三個時鐘都 `create_clock`；dac_clk 與 tx_clk 是 2:1 同步關係（真實設計來自 BUFGCE_DIV）——OOC 中用 `create_generated_clock -divide_by 2` 或兩個同源時鐘表達這種關係，不准設為非同步。
   - host_clk ↔ tx_clk：只對同步器第一級、格雷碼指標、握手資料用 `set_max_delay -datapath_only <目的週期>` 及 `set_bus_skew`；`xpm_fifo_async` 用它自帶的約束。不准整組 `set_clock_groups`。

## 驗收（固定）

1. T1–T6 全 PASS（貼出計數），CRC 仍為 `D49307A0`。
2. OOC 實現：每個域內與每一對跨域 WNS ≥ 0、WHS ≥ 0（兩張表，數字取自 `report_timing_summary`）。
3. `report_cdc`：無未處理的 Critical；Warning 逐條說明。
4. 資源：URAM 56；BRAM ≤ 2 塊 RAMB36（若 FIFO 用 block）。
5. 同一失敗最多修 2 輪；仍失敗就停，報告 `NEEDS_PARENT_JUDGMENT`，附最差 10 條路徑。
