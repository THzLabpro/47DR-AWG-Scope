# D0_CLOCK_PROBE — 重建 BD（9.8 GS/s / 5 GS/s）+ 612.5 MHz 時序探測

先讀 `AGENTS.md`、`doc/00_ETH_PLAN.md` §6、`doc/01_DATAPATH_V2.md`（凍結）。

## 背景

- 已上板的 9 GS/s 包在 `../rf_awg_scope_v1/hardware/dac9g_opt1/`（bit/xsa/ltx/elf、timing/clock 報告），但產生它的 Vivado 工程（`E:/47dr_ADDA/...`）已不存在，
  而且倉庫 `rtl/` 不是上板版本。BD 是 `reference/system/system.bd`（舊設定）再經 `scripts/build.tcl`、`build_9g_candidate.tcl`、`build_9g_mts_candidate.tcl`、`build_adc_readback_fix_20261110.tcl` 一連串修改得到。
  上板版頂層是 `rtl/candidates/dac9g_mts/adaloop_top.v`（含 PL SYSREF 同步、pl_clk BUFG、adc_fabric_ref）。
- 已上板 XSA 內的 `.hwh` 有完整的 BD 參數（RFDC、PS、clk_wiz、reset），是重建的依據。
- 本任務的目的：(1) 得到一份**從零可重建**的 BD 腳本，參數改成 v2；(2) 用代表性的 TX/RX 邊界層和 RAM 幾何跑完整 impl，確認 612.5 MHz 與 416.667 MHz 域能收斂。

## 歸屬檔案（只能寫這些）

- `scripts/bd/**`（BD 重建腳本）、`scripts/d0/**`（建置/報告腳本）
- `rtl/d0/**`（探測用頂層與 TX/RX stub，之後不進正式設計）
- `constraints/d0/**`
- `build/D0/**`、`reports/D0/**`

## 要做的

1. 解開 `../rf_awg_scope_v1/hardware/dac9g_opt1/rf_awg_scope_v1.xsa`（到 `build/D0/xsa/`），從 `.hwh` 匯出所有 IP 的 CONFIG 參數到 `reports/D0/published_bd_params.txt`。
2. `scripts/bd/create_system_v2.tcl`：在空工程中從零建立 BD `system`：
   - PS（照 hwh 的 PSU 設定，含 DDR、pl_clk0 100 MHz、M_AXI_HPM 給 RFDC AXI-Lite、復位）。
   - RFDC：除 doc/01 §1 指定的取樣率/模式外，其他參數照 hwh（MTS、SYSREF、PLL 參考 200 MHz、tile 啟用、clock 分配）。DAC 9.8 GS/s、`DAC_Mode`=3、x1、16 樣點/拍；ADC 5.0 GS/s、x1、12 樣點/拍。
   - DAC fabric 時鐘 612.5 MHz、ADC fabric 時鐘 416.667 MHz 的產生方式照 hwh 中 clk_wiz 的結構（v1 是 DAC 由 RFDC clk_dac2 經 MMCM，ADC 由 LMK PL_CLK 經 MMCM），只改頻率；寫明 MMCM 的 VCO/分頻設定。
   - 對外埠名稱與 `rtl/candidates/dac9g_mts/adaloop_top.v` 期望的一致（可另加，但不得刪）。
   - 腳本最後 `validate_bd_design`，並把產生的 RFDC 參數與 hwh 逐項 diff 到 `reports/D0/bd_param_diff.txt`（預期差異只有 doc/01 §1 的項目和由它推導出的時鐘）。
3. `rtl/d0/d0_probe_top.v`：以 `rtl/candidates/dac9g_mts/adaloop_top.v` 的時鐘/SYSREF/MTS 接法為準，但資料路徑換成：
   - TX：`tx_clk` = `dac_clk` 經 BUFGCE_DIV ÷2；每通道一個 **與正式設計同幾何** 的 stub 緩衝（7 塊 URAM288 並排，4096 深，504 bit 讀出，取 448 bit 解包成 32 × 16 bit = 512 bit），
     位址循環遞增；再經 2:1 寬度轉換（512@306.25 → 256@612.5，同源時鐘，用暫存器選半邊）和一級暫存器送 RFDC s_axis。URAM 內容可由一個簡單的 host 寫口（例如 PS AXI GPIO 或固定初值）提供，但不得讓 Vivado 把 URAM 優化掉（用 DONT_TOUCH 或可觀測輸出）。
   - RX：RFDC m_axis（192 bit @416.667）→ 一級暫存器 → 1:2 加倍（384 bit @208.333）→ 取每樣點高 14 bit 打包 336 bit → 每通道一塊 2730×336 的 BRAM（寫入位址循環）；讀口接到 host_clk（例如一個 32 bit 讀出多工器，能被觀測即可）。
   - 不要 ILA、不要 JTAG-AXI、不要光口。
4. 約束：`constraints/d0/`，含 pl_clk/sysref 管腳（照 v1 `constraints/board.xdc`）、必要的 CDC、`tx_clk/dac_clk` 與 `rx_clk/adc_clk` 為同源分頻（不得設成 async）。
5. 建置：`scripts/d0/build_d0.tcl`（`set_param general.maxThreads 20`、`launch_runs -jobs 8`），synth → impl（預設策略）→ `report_timing_summary`、`report_utilization`、`report_clock_utilization`、`report_methodology`、`report_cdc` 存到 `reports/D0/`。
   - 若 612.5 MHz 或 416.667 MHz 域不收斂：最多 2 輪調整（例如 `Performance_Explore`、`phys_opt_design -directive AggressiveExplore`、靠近 RFDC 的 pblock、多一級暫存器）。每輪記錄 WNS 和最差路徑。
   - 不產生 bit（`write_bitstream` 可做可不做，但不得對硬體下載）。

## 驗收（固定）

1. `create_system_v2.tcl` 在乾淨目錄可重跑，`validate_bd_design` 0 error；`bd_param_diff.txt` 只含預期差異（逐條解釋）。
2. impl 完成；報告各時鐘域的 WNS/TNS/WHS，特別是 `dac_clk`(612.5)、`tx_clk`(306.25)、`adc_clk`(416.667)、`rx_clk`(208.333)。
3. 利用率：URAM 應為 56、RX BRAM 約 8×(28~30) 塊；報告實際值。
4. 若最終未收斂，報告最差 10 條路徑的起訖點、邏輯級數、佈線延遲比例，以及建議，狀態 `NEEDS_PARENT_JUDGMENT`。
