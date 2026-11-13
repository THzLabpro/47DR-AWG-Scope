# D0R2_TIMING 報告

日期：2026-11-11  
狀態：`NEEDS_PARENT_JUDGMENT`

## 完成項目

- 更新 [d0_probe_top.v](../../rtl/d0/d0_probe_top.v)：加入 dac/tx/adc/rx/host 各域兩級 ASYNC_REG reset synchronizer，按通道複製 reset；資料路徑暫存器不接 reset。TX URAM 使用 `READ_LATENCY_B=3`，加入兩級無 reset TX 流水，DAC mux 選擇信號按負載分成四份。RX 改成 5 組 BRAM bank，複製寫地址/使能/讀地址，寫資料多打一拍，host 讀延遲為 2；host BRAM 讀口只由 host 域 reset/enable 控制。
- 更新 [d0_timing.xdc](../../constraints/d0/d0_timing.xdc)：從實際 pin 取得 host/RF/PL 時鐘；host 對 RF 時鐘設任務要求的 asynchronous clock group；只對 SYSREF 兩個第一級同步器設 `set_max_delay -datapath_only`。BUFGCE_DIV 兩組 2:1 時鐘仍保持同步時序，沒有新增 false_path 或其他 clock_groups。
- 新增 [build_d0r2.tcl](../../scripts/d0/build_d0r2.tcl) 與 [validate_d0r2_xdc.tcl](../../scripts/d0/validate_d0r2_xdc.tcl)，輸出隔離於 D0R2_TIMING。建置 Tcl 逐項 assert 六個時鐘 pin/clock 非空與三個 SYSREF pin 存在，`set_param general.maxThreads 20`，實現前檢查 Vivado 行程數。
- 使用已驗證 D0 BD 專案副本完成 D0R2 route。BD 參數 diff 使用 published XSA 參數與已驗證 BD dump 比較：`changed=15`、`unexpected=0`。沒有修改 `scripts/bd/create_system_v2.tcl`。

## 固定驗收

| 項目 | 結果 | 證據/說明 |
|---|---|---|
| 1. BD diff、DRC、route | PASS | `unexpected=0`；DRC 0 error；61,533/61,533 routable nets fully routed，0 routing error、0 unrouted、0 partially routed。DRC 有 1 條 RTSTAT-10 warning：48 個無 routable load 的 RFDC 狀態網。 |
| 2. 域內與跨域時序 | PASS | routed `report_timing_summary`：所有 WNS/WHS 非負，TNS/THS 均為 0；整體 WNS `+0.193 ns`、WHS `+0.010 ns`。 |
| 3. CDC | FAIL | 詳細 `report_cdc` 有 12 個 Critical（8 個 CDC-11、4 個 CDC-13），端點位於生成的 RFDC BD/IP；另有 84 個 CDC-15 Warning。需要 parent 判斷是否接受/協調 RFDC IP 的內部 CDC。 |
| 4. 資源 | PASS | URAM288 56；RAMB36 224；RAMB18 8。 |
| 5. pblock 條件 | N/A | 預設實現後 WNS/WHS 均非負，沒有符合「邊界路徑因 route >60% 而失敗」的觸發條件；未加 pblock。 |

驗收計數：PASS 3、FAIL 1、N/A 1。第 3 項未通過，因此整體狀態為 `NEEDS_PARENT_JUDGMENT`。預設實現已滿足 setup/hold，沒有啟動替代策略；本輪不需要第二次 timing 修正。

### 域內時序

數字直接取自 `reports/D0R2_TIMING/timing_summary.rpt` 的 Intra Clock Table。報告中的 clock object 對應：`dac_clk=clk_out1_system_clk_wiz_0_0`、`tx_clk=tx_clk`、`adc_clk=clk_out1_system_clk_wiz_adc_0`、`rx_clk=rx_clk`、`host_clk=clk_pl_0`。

| 域 | WNS (ns) | TNS (ns) | WHS (ns) | 判定 |
|---|---:|---:|---:|---|
| dac_clk | +0.263 | 0.000 | +0.041 | PASS |
| tx_clk | +0.512 | 0.000 | +0.010 | PASS |
| adc_clk | +0.580 | 0.000 | +0.028 | PASS |
| rx_clk | +1.811 | 0.000 | +0.021 | PASS |
| clk_pl_0 / host_clk | +2.531 | 0.000 | +0.017 | PASS |

### 跨域時序

數字取自 `Inter Clock Table`。`N/A` 表示該例外沒有對應的 min-delay hold path，不代表 0 ns。

| 起始域 → 目的域 | WNS (ns) | WHS (ns) | 關係/約束 |
|---|---:|---:|---|
| tx_clk → dac_clk | +0.256 | +0.041 | BUFGCE_DIV 2:1 同源時鐘；同步時序 |
| adc_clk → rx_clk | +0.673 | +0.011 | BUFGCE_DIV 2:1 同源時鐘；同步時序 |
| pl_clk_p → dac_clk | +0.737 | N/A | SYSREF 第一級；`set_max_delay -datapath_only 1.633 ns` |
| pl_clk_p → adc_clk | +0.672 | N/A | SYSREF 第一級；`set_max_delay -datapath_only 2.400 ns` |
| clk_pl_0 → dac_clk | N/A | N/A | `set_clock_groups -asynchronous`；不作 timing signoff |
| clk_pl_0 → tx_clk | N/A | N/A | `set_clock_groups -asynchronous`；不作 timing signoff |
| clk_pl_0 → adc_clk | N/A | N/A | `set_clock_groups -asynchronous`；不作 timing signoff |
| clk_pl_0 → rx_clk | N/A | N/A | `set_clock_groups -asynchronous`；不作 timing signoff |

Summary 另列的 `**async_default**` path group 數字如下，保持 Vivado 原分類，沒有用它們替代上表的同步/指定例外關係：

| 起始域 → 目的域 | WNS (ns) | WHS (ns) | Vivado path group |
|---|---:|---:|---|
| dac_clk → dac_clk | +0.193 | +0.123 | `async_default` |
| adc_clk → adc_clk | +0.486 | +0.128 | `async_default` |
| clk_pl_0 → clk_pl_0 | +5.900 | +0.272 | `async_default` |
| adc_clk → rx_clk | +0.645 | +0.203 | `async_default` |
| rx_clk → rx_clk | +2.298 | +0.088 | `async_default` |
| dac_clk → tx_clk | +0.455 | +0.077 | `async_default` |
| tx_clk → tx_clk | +0.349 | +0.454 | `async_default` |

### CDC 詳情與協調

`cdc_details.rpt` 列出 12 個 Critical：

- 8 個 CDC-11：`rst_rf_clk`/`rst_adc_clk` 的 reset 輸出到 RFDC 內部 `cdc_dac[0-3]_clk_valid_i` 與 `cdc_adc[0-3]_clk_valid_i` 的第一級同步器 D pin。
- 4 個 CDC-13：RFDC 內部 `adc[0-3]_cmn_control_ff_reg[12]` 到 ADC tile `CONTROL_COMMON[12]` 的非 FD primitive 路徑。

它們位於 `system_i/usp_rf_data_converter_0/inst/...` 生成 IP 階層，不在本任務可修改的 `rtl/d0/**` 或 timing XDC 中；本任務沒有用 clock exception 掩蓋這些 Critical。這是第 3 項未通過的原因，需 parent/Claude 協調 RFDC BD/IP reset 與內部 CDC 的處理方式。

另有 84 個 CDC-15 Warning，全部描述 `Clock enable controlled CDC structure detected`：RFADC0–3 各 8 條、RFDAC0–3 各 8 條，位於 RFDC status/AXI `IP2Bus_Data_reg` 讀回路徑；ADC fabric clock 到 `clk_pl_0` 有 20 條 marker/status 讀回路徑。這些路徑在 RFDC 生成 IP 內，由其 clock-enable/status 讀取結構處理；未新增或改動相應 false_path。Warning 與端點清單見 `cdc_details.rpt`。

本探測設計的使用者可見 CDC 點：

- `pl_clk_p` SYSREF 先在 `pl_clk` 暫存，再分別進 `sysref_dac_meta`/`sysref_adc_meta` 第一級 ASYNC_REG；兩條最大延遲均由目的時鐘週期限制。
- `dac_clk ↔ tx_clk` 與 `adc_clk ↔ rx_clk` 是 BUFGCE_DIV ÷2 同源時鐘；保留同步 timing，TX/RX gearbox/packer 邊界沒有例外約束。
- host 對 RF 時鐘使用 asynchronous clock group。RX host 讀口透過五組 independent-clock XPM BRAM 從 rx_clk 寫入、host_clk 讀出；這是探測器的雙時鐘記憶體邊界，不是 ASYNC_REG/toggle handshake。請 parent 確認此探測邊界是否符合「host↔RF 僅經同步器/握手」的架構假設。
- 各 reset 輸入在 dac/tx/adc/rx/host 域各自經兩級 ASYNC_REG 同步，並按通道複製；XPM simple dual-port RAM 可用的 `rstb` 綁低（該 XPM 沒有 `rsta` port），BRAM host `enb/regceb` 僅由 host 域控制。

`check_timing.rpt` 顯示 0 unconstrained internal endpoints、0 no-clock endpoints；另有 1 個未設 input delay 的 `pl_sysref_p` 與 2 個未設 output delay 的 LED pins，屬本探測 top 的外部 I/O，非固定 timing acceptance 的域內路徑。沒有使用無依據 false_path、clock_groups 或判據放寬。

## 命令與結果

- `py -X utf8 scripts/d0/extract_hwh_params.py --xsa ../rf_awg_scope_v1/hardware/dac9g_opt1/rf_awg_scope_v1.xsa --extract-dir build/D0R2_TIMING/xsa --report reports/D0R2_TIMING/published_bd_params.txt`：PASS，抽出 9 個 HWH modules。
- `py -X utf8 scripts/d0/compare_bd_params.py --published reports/D0R2_TIMING/published_bd_params.txt --bd build/D0/bd_params_v2.txt --out reports/D0R2_TIMING/bd_param_diff.txt`：PASS，`changed=15 unexpected=0`。
- Vivado 2025.2 `-mode batch -source scripts/d0/build_d0r2.tcl -tclargs build/D0R2_TIMING default_only`，環境先設 `PROCESSOR_ARCHITECTURE=AMD64`、`NoDefaultCurrentDirectoryInExePath=$null`：PASS，綜合完成、預設策略 route 完成、DRC 0 error、最終 timing summary 記錄整體 WNS `+0.193 ns` / WHS `+0.010 ns`。
- Vivado 2025.2 `-mode batch -source scripts/d0/validate_d0r2_xdc.tcl`：PASS，最終 routed DCP 可解析新 XDC；`read_xdc` 沒有 unsupported-command 或 path-segmentation warning；詳細 CDC 報告列出 12 Critical、84 Warning。
- `git diff --check`：PASS，無 whitespace error。
- 未產生 bitstream；未操作硬體、hw_server、JTAG 或 192.168.42.x。

關鍵報告：`timing_summary.rpt`、`worst_paths_setup.rpt`、`worst_paths_hold.rpt`、`clock_interaction.rpt`、`check_timing.rpt`、`cdc.rpt`、`cdc_details.rpt`、`drc.rpt`、`route_status.rpt`、`utilization.rpt`、`bd_param_diff.txt`。預設策略 timing 已通過，因此未執行替代策略，也未加 pblock。最終裁定仍等 RFDC 內部 Critical CDC 與雙時鐘 BRAM 探測邊界由 parent 確認。

## Claude 審查判定（2026-11-11）：PASS（附條件）

- 全晶片 route 後各域與跨域 WNS/WHS 全部非負（dac_clk +0.263、tx_clk +0.512、adc_clk +0.580、rx_clk +1.811、clk_pl_0 +2.531；tx→dac +0.256、adc→rx +0.673）。612.5 / 416.667 MHz 邊界層方案成立。
- 12 個 CDC Critical 全部位於 `usp_rf_data_converter_0/inst` 內部：
  - CDC-11 ×8：BD 的 `rst_rf_clk`/`rst_adc_clk` → RFDC IP 自帶 `cdc_{dac,adc}N_clk_valid_i/syncstages_ff` 同步器（IP 內建兩級同步，扇出到 4 個 tile 屬設計如此）。
  - CDC-13 ×4：`adcN_cmn_control_ff_reg` → RFDC hard block `CONTROL_COMMON`，由 AXI 設定、準靜態。
  兩者都是廠商 IP 標準連線（v1 已上板同樣結構），D3 用 `create_waiver` 逐條加說明，不做其他處置。
- RX host 讀口為雙時鐘 BRAM（rx_clk 寫、host_clk 讀）：協定上 host 只在擷取 done（已同步）後讀，屬合法用法；D3 保留並在 CDC 報告中說明。
