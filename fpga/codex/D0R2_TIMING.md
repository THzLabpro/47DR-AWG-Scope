# D0R2_TIMING — D0 探測設計時序修正（第二輪）

先讀 `AGENTS.md`、`doc/01_DATAPATH_V2.md`（凍結）、`reports/D0/report.md`、`reports/D0/timing_summary.rpt`。

## 背景（Claude 審查 D0 第一輪的結論）

第一輪 route 完成但四個 RF 域都是負 WNS。審查最差路徑後，**全部是探測設計本身的問題**，不是 612.5 / 416.667 MHz 做不到：

| 現象 | 路徑 | 原因 |
|---|---|---|
| clk_pl_0 組 -8.67 ns | `rst_adc_clk` → RX BRAM host 口 `ENBWREN/RSTRAMB` | host 讀口用了 ADC 域 reset；且 XDC 的 `set_clock_groups` 用了不存在的時鐘名（`data_clk`、`adc_capture_clk`）加 `-quiet`，實際沒套上 |
| dac 域 -1.79 / adc 域 -2.32 | `pl_sysref_r` → `sysref_{dac,adc}_meta` | SYSREF 同步器第一級沒有 CDC 約束；`adc_clk` 是 `pl_clk_p` 的 MMCM 子時鐘，200→416.667 邊沿間距極小 |
| 612.5 域內 -0.70 | `rst_rf_clk` proc_sys_reset 內部 | proc_sys_reset 不該跑在 612.5 MHz |
| 612.5→tx_clk -1.20 | `rst_rf_clk` → 3584 個 `tx_word_reg/R` | 跨域未同步的 reset 扇出到資料暫存器 |
| tx_clk 域內 -0.62 | URAM `CLK` → `tx_word_reg` | `READ_LATENCY_B=1`，URAM 沒用輸出暫存器 |
| tx_clk→dac_clk -0.54 | `tx_word_reg` → `dac_tdata_reg`，route 1.78 ns | tx 暫存器緊貼 URAM，離 RFDC 太遠，跨域前沒有可搬移的流水級 |
| adc 域內 -0.61 | RFDC `FABRIC_CLK` → `adc_stage_reg`，route 2.0 ns | 第一級暫存器有 reset、扇出多，被拉離 RFDC |
| rx_clk 域內 -0.63 | `wr_addr_reg` → 30 塊 BRAM `ADDR`，route 3.74 ns | 寫地址未複製 |

## 歸屬檔案（只能寫這些）

- `rtl/d0/**`、`constraints/d0/**`、`scripts/d0/**`
- `scripts/bd/create_system_v2.tcl`：**只允許**改 reset 相關連線（例如不再用 `rst_rf_clk`/`rst_adc_clk` 直接驅動 RF 域邏輯），其他 BD 參數不准動；改了要重跑 BD 參數 diff，`unexpected` 必須仍為 0。
- `build/D0R2_TIMING/**`、`reports/D0R2_TIMING/**`

## 要做的（按順序）

1. **XDC CDC 約束改寫**（`constraints/d0/d0_timing.xdc`）
   - 時鐘一律用 `get_clocks -of_objects <pin>` 取得，不准用猜的名稱，不准 `-quiet`；腳本裡對每個取得的時鐘清單 assert 非空，空就 `error`。
   - host（`clk_pl_0`）與 RF 時鐘（dac/tx/adc/rx）之間：`set_clock_groups -asynchronous`。依據：所有 host↔RF 跨域都只經過 ASYNC_REG 同步器或 toggle/handshake（報告中列出每一個跨域點）。
   - SYSREF：`pl_clk_p` → `sysref_{dac,adc}_meta`（ASYNC_REG 第一級）用 `set_max_delay -datapath_only <目的時鐘週期>`，只套在這兩組暫存器上；不要把 `pl_clk_p` 與 adc/dac 整組設為非同步。
   - 612.5↔306.25、416.667↔208.333 保持同步時序（BUFGCE_DIV 2:1），**不准**加任何例外。
2. **Reset 重做**
   - 每個域（dac、tx、adc、rx、host）各自一個 reset 同步器（非同步斷言、同步釋放，ASYNC_REG ≥ 2 級），之後用暫存器複製樹（`MAX_FANOUT` 或手動複製）。
   - proc_sys_reset 的輸出只作為這些同步器的非同步輸入，不直接驅動 RF 域邏輯。
   - **資料路徑暫存器不接 reset**：`tx_word`、`dac_tdata`、`adc_stage`、`adc_prev`、`packed_next`、寫資料等。只有 valid/enable/指標/狀態機接 reset。
   - URAM/BRAM 的 `rsta/rstb` 接 0；RX BRAM host 讀口的 `enb/regceb` 只能由 host 域訊號驅動。
3. **TX（tx_clk / dac_clk）**
   - URAM `READ_LATENCY_B` ≥ 3（用上 OREG），不用 cascade（7 塊並排，各自獨立）。
   - URAM 輸出到 612.5 MHz 選擇器之間，在 tx_clk 加 ≥ 2 級無 reset、無其他扇出的流水級，讓工具把最後一級放到 DAC tile 附近。
   - dac_clk 域：`half_select` 複製（每 32~64 個負載一份），`dac_tdata` 直接接 RFDC，中間只有一級 LUT（2:1 mux）。
4. **RX（adc_clk / rx_clk）**
   - RFDC `m_axis` 之後第一級 `adc_stage` 不接 reset、只扇出到下一級；第二級之後才做 2:1 合併與 14 bit 打包。
   - 寫地址、寫使能在 rx_clk 域按 BRAM 組複製（例如每 4~8 塊一份），寫資料多打一拍。
   - host 讀口 `READ_LATENCY_B` = 2。
5. 若做完 1~4，612.5 或 416.667 的邊界路徑仍因走線（route > 60%）失敗：為邊界暫存器加 pblock，放在對應 RFDC tile 所在的時鐘區域（從 routed DCP 查 RFDC site 位置，寫入報告）。
6. 實現：先用預設 directive；仍有負 slack 再試**最多 1 個**替代策略（例如 `Performance_ExplorePostRoutePhysOpt`）。腳本開頭 `set_param general.maxThreads 20`。啟動 Vivado 前照 AGENTS.md 規則 12 檢查行程數。

## 驗收（固定）

1. BD 參數 diff `unexpected=0`；DRC 0 error；0 unrouted。
2. 報告兩張表，數字取自 `report_timing_summary`：
   - **域內**：dac、tx、adc、rx、clk_pl_0 各自 WNS/TNS/WHS。
   - **跨域**：每一對有路徑的時鐘的 WNS/WHS，並標明它是同步時序、`max_delay -datapath_only` 還是 clock group。
   全部 WNS ≥ 0、WHS ≥ 0 為 PASS。
3. `report_cdc` 無 Critical 未處理項（列出 Warning 並逐條說明）。
4. 資源與第一輪一致（URAM 56；RAMB36 約 224）。
5. 同一失敗最多修 2 輪；仍失敗就停，報告 `NEEDS_PARENT_JUDGMENT`，附剩餘最差 10 條路徑的 source/destination/logic levels/route 比例。
