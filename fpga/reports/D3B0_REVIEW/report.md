# D3B0_REVIEW — 全晶片佈線前只讀審查（Claude 執行）

日期 2026-11-11。

**執行者**：Codex 後端當時沒有回應，改由 Claude 執行。
- 第 1 次（max）：一個指令都沒執行，就回報「看不到 D 槽」。
- 第 2 次（max）、第 3 次（xhigh）：7 分鐘、4 分鐘內都沒有任何指令輸出。
- 紀錄在 `codex/logs/failed/`。
- 第 3 次在被停止前留下 `checkpoint_copy.txt` 和一份 DCP 複本（sha256 與原檔一致），沒有其他寫入。

**審查對象**：D3A6 的綜合結果（commit e2e9d25）。
- 以 `open_project -read_only` 打開工程，`open_run synth_1`，再 `source constraints/top/cdc.tcl`（與 impl 的 OPT_DESIGN.TCL.PRE 相同）。
- 腳本：`build/D3B0_REVIEW/review.tcl`。
- 報告都在本目錄。
- 沒有跑 place、route、bitstream，也沒有任何硬體操作。

## 發現清單

### S1【必修，D3B 前】`tx_phase_tog` / `tog_q` 扇出 1797，612.5 MHz 跨域路徑

**證據**
- `probe.txt`：`tog_q_reg cells=1`。32 份複本 D 端相同，被綜合合併。
- `high_fanout.rpt`：`tx_i/tx_phase_tog` fo=1797（tx_clk）、`tx_i/tog_q_reg[0]` fo=1795（dac_clk）。
- 每一個 `dac_tdata_reg` 位元都是一個 LUT6，同時讀這兩個信號。

**時序現況**
- 路徑是 tx_clk → dac_clk，預算 1.633 ns，clock skew −0.40 ns。
- 綜合估計：dac 域 WNS 0.080 ns；這條路徑本身 slack 0.709 ns，但用的是未擺放時的 0.249 ns 繞線估計。
- 1797 扇出橫跨 8 個通道，擺放後繞線很可能超過 1 ns。

**判定**：極可能時序不收斂。

**建議修法**（功能與 D3A6 相同，已推導）
- 相位改在 dac 域**先打一拍**：
  ```
  fh_q[i] <= (tx_phase_tog_r[k] == tog_q[i])
  ```
  再用 `fh_q[i]` 當選擇信號。
- 推導（tx 邊緣 E0、E2；dac 邊緣 E0、E1、E2）：
  - E0 取樣時 tog 尚未翻轉，tog_q 也是舊值 → `fh_q=1`，所以 E1 送 `[255:0]`。
  - E1 取樣 tog（新）≠ tog_q（舊）→ `fh_q=0`，所以 E2 送 `[511:256]`。
- 複本與扇出：
  - `tx_phase_tog` 在 tx 域複製 8 份（每通道一份）。
  - `tog_q`、`fh_q` 各 32 份。
  - 全部加 `(* DONT_TOUCH = "TRUE" *)`。
  - 跨域扇出降到約 8，選擇信號扇出約 56，而且都從暫存器出發。
- start event 用 `fh_q[ch*4]`。
- 驗證：TX 單元 TB（兩種 reset 相位）、系統 TB、綜合重跑。

### S2【建議 D3B 前修】RX `adc_phase` 扇出 2690，416.667 MHz，而且相位隨開機變

**證據**
- `high_fanout.rpt`：`rx_i/adc_phase` fo=2690（adc_clk，2.4 ns），當 `adc_pair_data_q` 的 CE。
- RTL：`rtl/rx/awg_rx.sv:78-108`。

**問題**
- `adc_phase` 和 D3A6 之前的 TX 一樣，只在 reset 時設值，之後自由翻轉，沒有對齊 rx_clk。
- 樣點順序固定是「前拍＋本拍」，所以不會錯序。
- 但每次開機，配對邊界與擷取延遲會差 1 個 adc 拍，也就是 12 點。觸發對齊因此每次開機不同；現行判據 ±24 字容得下。

**建議修法**
- 照 S1 的做法：rx_clk 域放翻轉旗標，adc 域比較後打一拍成 `pair_phase_q`，每通道一份並加 DONT_TOUCH。
- 修完後延遲固定，扇出也降下來。

### S3【建議 D3B 前修】JTAG 備援的 dbg_hub 設定缺失

- 已上板的 `../rf_awg_scope_v1/constraints/timing.xdc` 有：
  - `C_CLK_INPUT_FREQ_HZ 100000000`
  - `C_ENABLE_CLK_DIVIDER false`
  - `C_USER_SCAN_CHAIN 1`
  - `connect_debug_port dbg_hub/clk [get_nets fclk_100m]`
- 本工程沒有這些設定：
  - dbg_hub 時鐘由工具自動選。
  - 預設時鐘頻率是 300 MHz，與實際的 100 MHz 不符。
  - `CKLD-1` 顯示 `sl_iport0[1]` 是非緩衝時鐘網路、超過 512 個負載。
- 建議：把這四行加進 `constraints/top/timing.xdc`。必須放在 XDC 裡，因為 dbg_hub 在 opt_design 才建立，OPT PRE 的 Tcl 看不到它。

### S4【D3B 腳本必補】`scripts/d3/build_d3.tcl` 實現段落不完整

- `DO_IMPLEMENTATION` 段落只有 `launch_runs impl_1 -to_step route_design`，缺少：
  - `write_bitstream`；
  - `write_hw_platform -fixed -include_bit`（F1 韌體要用的 XSA）；
  - post-route 報告：timing_summary、route_status、drc、methodology、power、clock_utilization、cdc。
- build 與 report 目錄寫死為 `D3A6_INTEGRATION`，D3B 要改成參數。
- `wait_on_run` 之後沒有檢查 `PROGRESS` / `STATUS`，失敗時不會報錯。

### S5【建議 phys_opt 處理】其他高扇出網路

| 網路 | 扇出 | 時鐘 | 綜合估計 WNS |
|---|---|---|---|
| `tx_i/tx_word_reg[0][511]_i_2_n_0`（LUT2，CE） | 3584 | tx_clk 3.266 ns | 0.745 |
| `tx_i/uram_rd_stage0[*][*][71]_i_1_n_0`（LUT3，×8） | 896 | tx_clk | 同上 |
| `rx_i/capture_fire`（LUT6） | 2895 | rx_clk 4.8 ns | 2.877 |

建議 D3B 用以下方式處理，不另改 RTL：
- `opt_design -directive Explore`；
- 擺放後 `phys_opt_design -directive AggressiveExplore`；
- 若 WNS < 0，再跑 post-route `phys_opt_design`。

### N1【已查，無問題】DRC 與腳位

- `drc_synth.rpt`：0 個 Error / Critical。
- Warning 都是無害項：DSP pipelining、BUFG_GT 無負載 ×7、BUFGCE 無負載、BUFGCE_DIV 由 BUFG 驅動 ×2 等。
- 所有非 GT 埠都有 PACKAGE_PIN 與 IOSTANDARD，沒有 NSTD-1 / UCIO-1。
- 逐腳比對結果：
  - `pl_clk` E12/D12、`pl_sysref` E14/D14（LVPECL）、LED B12/A12（LVCMOS18）：與 `rf_awg_scope_v1/constraints/board.xdc` 一致。
  - QSFP2 refclk H28/H29、TX/RX 8 對、`reset_n` D13（LVCMOS18）、`lpmode` B10、`modsel_n` C10（LVCMOS33）：與 `rf_udp_link_v3/constraints/eth/qsfp2_udp_echo.xdc` 一致。
  - `CONFIG_VOLTAGE 1.8`、`CFGBVS GND`、`BITSTREAM.GENERAL.COMPRESS TRUE`：與 v3、scope_v1 一致。

### N2【已查，無問題】時鐘

`probe.txt` / `clocks.rpt`：

| 時鐘 | 週期 (ns) | 對應頻率 |
|---|---|---|
| `clk_out1_system_clk_wiz_0_0` | 1.633 | 612.5 MHz |
| `tx_clk`（BUFGCE_DIV 自動推導） | 3.266 | ÷2 |
| `clk_out1_system_clk_wiz_adc_0` | 2.400 | 416.667 MHz |
| `rx_clk`（BUFGCE_DIV 自動推導） | 4.800 | ÷2 |
| GT `txoutclk` / `rxoutclk` | 3.2 | |
| `TXOUTCLKPCS` | 3.103 | |
| `qsfp2_refclk` | 6.4 | 156.25 MHz |

- `clock_interaction.rpt`：無 unsafe。
- 綜合估計各域 setup WNS 皆 ≥ 0，最小是 dac 域 0.080（見 S1）。hold 負值在擺放前屬正常。

### N3【已查】方法論與例外

- `TIMING-17` ×1000：jtag_axi / dbg_hub 的 no_clock，D3A6 已分類；S3 修後應減少。
- `TIMING-54` ×1：`clk_out1_demo_management_clock` 與 `clk_pl_0` / GT 時鐘之間的 scoped clock group。來自光口 IP 的 XDC，v3 已上板的版本相同，接受。
- `TIMING-18` ×3：LED / QSFP 控制腳沒有 IO delay，是靜態信號，接受。
- `exceptions_ignored.rpt`：被忽略的都是 IP 自帶約束中找不到物件的項目（GT reset synchronizer、RFDC FABRIC_CLK 萬用字元），不是本專案的約束。

### N4【已查，F1 要改】韌體（不在本任務範圍，只列出）

`software/src/main.c`：

| 行 | 現值 | 應改為 |
|---|---|---|
| :76 | `DAC_EXPECTED_RATE_GSPS 9.0` | 9.8 |
| :78 | `DAC_FABRIC_CLOCK_HZ 562500000U` | 612500000U |
| :413 | 開機訊息「DAC=9000000000」 | 改成 9.8 G |
| :415 | 「load wave RAM and START using JTAG」 | 改成光口 |

- `rfsoc_cfg.c` 的 `change_baseSampleFreq()` 沒有被呼叫，RFDC 速率以 bitstream 為準。
- BSP 必須從 D3B 的新 XSA 重建（SDT 流程）。

### N5【已查，無問題】位址與網路參數

| 項目 | RTL | 主機工具 | doc |
|---|---|---|---|
| MAC | `02:47:41:00:00:02` | | doc/00 §4 一致 |
| IP | 192.168.42.2 | `cli.py` 預設一致 | 一致 |
| PC IP | 192.168.42.10 | | 一致 |
| UDP 埠 | 9100 | 一致 | 一致 |
| 控制暫存器基址 | | `REG_BASE = 0x90200000` | doc/01 §5 一致 |

- 韌體只使用 `XPAR_UP_AXI_0_BASEADDR`（user_control）與 RFDC，和 awg_control_v2 無關。

### N6【已查，無問題】啟動順序

- 光口 reset 只依賴 PS reset（`host_resetn_local` → `eth_reset_pipe`），不依賴 RFDC。
- TX 依賴 `config_done`，由韌體在 RFDC、MTS 完成後寫入 user_control reg7。
- 沒有發現循環相依。

### N7【已查】axil_arb2

- 一次只處理一筆交易，用輪詢 FSM 仲裁。aw/w/ar 先各自鎖存再仲裁，結構上不會死鎖。
- 現有 TB 沒有光口與 JTAG 同時存取的情境，這點無法由模擬證明。

### N8 功耗（綜合後估計，只報告）

- 總功耗 15.96 W，Tj 39.7 °C，可信度 Medium。
- 主要部分：RFAMS 8.99 W、PS8 2.47 W、GTY 1.25 W、URAM 0.42 W、Clocks 0.41 W。

### N9 資源（與 D3A6 相同）

| 資源 | 用量 | 比例 |
|---|---|---|
| LUT | 36926 | 8.7% |
| FF | 63238 | 7.4% |
| BRAM tile | 269 | 24.9% |
| URAM | 56 | 70% |
| GTY | 4 | 50% |
| MMCM | 4 | |
| BUFGCE_DIV | 2 | |

## D3B 建議

1. **先修 RTL**：S1、S2 只改 `awg_tx.sv`、`awg_rx.sv` 幾十行，S3 在 `timing.xdc` 加 4 行。
   修完重跑：TX 單元 TB（兩種 reset 相位；RX 單元 TB 加兩種 reset 相位）、RX、系統 TB、synth_1。
   **任一項模擬失敗就停在這裡，不進實現。**
2. **實現設定**：
   - `-jobs 2`，`maxThreads 20`；
   - 策略 `Performance_ExplorePostRoutePhysOpt`，或 opt Explore、place ExtraTimingOpt（D0R2 已收斂的設定），加上擺放後 `phys_opt` AggressiveExplore；
   - 不需要 pblock（D0R2 沒有用 pblock 也收斂了）。
3. **產出**：bitstream、XSA（`-fixed -include_bit`）、post-route 報告，判據 WNS ≥ 0、WHS ≥ 0、route 完成。
4. **預估時間**：綜合約 40 分鐘，實現約 1.5–2.5 小時。
