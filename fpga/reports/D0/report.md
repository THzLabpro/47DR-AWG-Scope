# D0_CLOCK_PROBE 報告

## 完成項目

- 解開 `../rf_awg_scope_v1/hardware/dac9g_opt1/rf_awg_scope_v1.xsa` 至 `build/D0/xsa/`，抽取 9 個 HWH module 的參數。
- 建立可重跑的 BD 重建腳本 `scripts/bd/create_system_v2.tcl`；`validate_bd_design` 完成，BD 參數 diff 為 15 條，`unexpected=0`。
- 建立 `rtl/d0/d0_probe_top.v`：8 通道 TX 7×504-bit URAM 幾何、RX 2730×336-bit BRAM 幾何、SYSREF synchronizer、612.5/306.25 與 416.667/208.333 時鐘邊界。
- 建立 `constraints/d0/d0_board.xdc`、`constraints/d0/d0_timing.xdc`。
- 建立 `scripts/d0/build_d0.tcl`、`scripts/d0/finalize_d0.tcl` 和參數抽取/比較 helper。

## 實際命令與結果

1. `py -X utf8 scripts/d0/extract_hwh_params.py ...`
   - PASS；`MODULES 9`。
2. `vivado.bat -mode batch -source scripts/bd/create_system_v2.tcl ...`
   - PASS；`validate_bd_design` 0 error。
3. `py -X utf8 scripts/d0/compare_bd_params.py ...`
   - PASS；`changed=15`、`unexpected=0`。
4. `vivado.bat -mode batch -source scripts/d0/build_d0.tcl ...`
   - 綜合 PASS：`synth_design Complete!`、0 errors。
   - 實現 route PASS：`route_design completed successfully`、DRC 0 errors、0 unrouted nets。
   - 最終報告由 routed DCP 以 `scripts/d0/finalize_d0.tcl` 產生。

## 時序

| domain | 頻率 | WNS (ns) | TNS (ns) | WHS (ns) | THS (ns) |
|---|---:|---:|---:|---:|---:|
| `dac_clk` | 612.5 MHz | -1.790 | -353.965 | 0.010 | 0 |
| `tx_clk` | 306.25 MHz | -1.203 | -2706.586 | 0.022 | 0 |
| `adc_clk` | 416.667 MHz | -2.321 | -383.018 | 0.005 | 0 |
| `rx_clk` | 208.333 MHz | -0.627 | -646.928 | 0.001 | 0 |

另外，跨域/host `clk_pl_0` path 的 worst setup WNS 為 -8.673 ns；最差路徑是 ADC reset domain 到 RX BRAM `ENBWREN`，data path 1.354 ns，其中 routing 1.240 ns、91.579%，clock skew -6.812 ns。完整前 10 條路徑在 `worst_paths_setup.rpt`。

## 利用率

- URAM288：56，符合 8 通道 × 7 塊。
- RAMB36：224；RAMB18：8，等效每通道 28 RAMB36 + 1 RAMB18，符合 RX 幾何預期。
- routed top-level：14210 LUT、20605 FF、0 DSP。

## 未完成與原因

- 時序未收斂，固定驗收要求的四個 RF clock domain 均有負 WNS；依規則不能用 false path 或放寬判據掩蓋，狀態為 `NEEDS_PARENT_JUDGMENT`。
- 建置腳本中的第二/第三輪 strategy 尚未執行；第一輪已完成 route 並保存 routed DCP。因第一輪已明確大幅負 slack，後續應由 parent 決定是否改變 reset/跨域拓撲或增加 pipeline。
- 未產生 bitstream，未對硬體、JTAG 或 192.168.42.x 發包。

## 需要協調

- HWH 舊版 AXIS 外部 interface metadata 與 v2 寬度不同；腳本已在 BD validation 層修正時鐘頻率，TDATA byte metadata 有 Vivado read-only 限制，需 parent 審查正式 BD interface 定義。
- 目前最差路徑主要落在 reset/host BRAM enable 與跨時鐘 skew；若要收斂，需 parent 決定是否允許調整 reset fanout、取消 probe host 讀口或增加額外 register stage。
