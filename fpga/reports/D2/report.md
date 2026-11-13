# D2_RX 執行報告

## 完成檔案

- `rtl/rx/awg_rx.sv`：八通道 ADC 擷取、14-bit 打包、雙時鐘 BRAM、觸發與 host 讀口。
- `sim/rx/tb_awg_rx.sv`、`sim/rx/run.ps1`：自檢 testbench 與 Vivado Simulator 執行入口。
- `build/D2/ooc.tcl`、`build/D2/run_ooc.ps1`：ZU47DR OOC 綜合、布局、物理優化、佈線及報告流程。
- 綜合/實作 checkpoint：`build/D2/awg_rx_synth.dcp`、`build/D2/awg_rx_impl.dcp`；仿真波形：`build/D2/sim/tb_awg_rx_sim.wdb`。
- 驗收日誌與報告：`reports/D2/` 下的 `xvlog.log`、`xelab.log`、`xsim.log`、`sim_result.txt`、`utilization_*.rpt`、`timing_*.rpt`、`setup_paths.rpt`、`hold_paths.rpt`、`route_status.rpt` 及 Vivado 執行日誌。

## 固定驗收

固定清單 3/3 PASS，0 FAIL。

1. R1–R4：PASS。R1 對 1、100、2730 words 的八通道讀回共比對 543,552 個樣點，0 mismatch、0 X；低兩位均為 0。host 讀回在 1 個 host_clk 週期返回。R2 20/20 相位測試 PASS，事件到擷取起點 9.957–14.173 ns，平均 12.168 ns，跨度 4.216 ns（小於一個 4.8 ns RX 週期）；`cap_tx_word` 與測試事件位置的循環差不超過 1 word。R3 busy 時再 arm 被忽略，讀請求不產生 `h_rd_valid`，原擷取仍完成 100 words。R4 全通道 `adc_tvalid` 掉一拍時跳過該 24-sample pair，繼續擷取至 480 個有效樣點；每通道各觀察到一個 24 點缺口，其他序列連續。
2. BRAM：PASS。實際使用 RAMB36E2=224、RAMB18E2=8，等效 RAMB36=228，低於上限 240；推論出 8 個 `2730×336` RAM。最終實作資源為 LUT=1089、FF=7128。
3. OOC impl：PASS。器件 `xczu47dr-fsve1156-2-i`。時序報告直接時鐘域 setup/hold：ADC `+0.144/+0.039 ns`、RX `+0.418/+0.055 ns`、host `+4.966/+0.066 ns`；相關 ADC→RX setup/hold `+0.289/+0.023 ns`。沒有負 slack。15,773 個 routable nets 全數 routed，routing errors=0。

R2 延遲分佈與 20 次逐次結果見 `xsim.log`。D2 OOC 邊界沒有包含外部 ÷2 時鐘器件，因此約束把 `adc_clk` 與同相 `rx_clk` 作為兩個 primary input clocks（2.4 ns / 4.8 ns）並直接計時 ADC→RX 路徑；沒有把這兩域設為非同步，也沒有使用 false path 或 multicycle path。

## 執行命令與結果

- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File sim/rx/run.ps1`：xvlog=0、xelab=0、xsim=0；`RESULT name=tb_awg_rx PASS compared=543552 mismatches=0 x_count=0 pass_items=24 fail_items=0`。
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File build/D2/run_ooc.ps1`：最終 OOC 執行 exit=0；啟動前 Vivado 行程數為 1（低於 3）。Tcl 開頭設定 `general.maxThreads 20`。
- OOC 最終數據：RAMB36=224、RAMB18=8、LUT=1089、FF=7128；WNS/WHS 與 routing 結果見上方及 `timing_impl.rpt`、`utilization_impl.rpt`、`route_status.rpt`。

迭代中曾修正仿真 `glbl` 連結、OOC 非工程讀取流程、ADC→RX 到 BRAM 的半週期寫入控制路徑及 Tcl 時鐘集合語法。第一次完整 OOC 佈線的 ADC→RX WNS 為 `-0.032 ns`；加上 RX 域寫入暫存並去掉首字地址選擇後，最終路徑收斂至 `+0.289 ns`。各輪日誌保留於 `vivado_ooc.log`、`vivado_ooc_retry1.log`、`vivado_ooc_retry2.log`、`vivado_ooc_retry3.log` 和 `vivado_launch.log`。

## 未完成與需要協調

- `tx_play_word[11:0]` 目前依任務指定的 binary-only RX 介面，使用 `xpm_cdc_array_single` 做目的端粗略同步。介面沒有 `tx_clk`、源端 Gray 指標或 request/ack 回握，故無法保證跨時鐘多位元快照一致。TB 的 20 次模擬結果只驗證指定相位下的粗略偏差，不能證明硬體跨域一致性。需由上層決定由 TX 提供 Gray-coded 指標/握手，或准許 RX 介面增加來源時鐘與相應同步方案；這是總狀態為 `NEEDS_PARENT_JUDGMENT` 的原因。
- OOC 頂層沒有 `HD.CLK_SRC` 位置資料，Vivado 提示無法估算外部 clock buffer delay/skew；ADC 輸入 ports 也沒有 `HD.PARTPIN_LOCS` / input delays，故外部 ADC 腳位至輸入暫存器的實體輸入路徑不在此 OOC timing signoff 內。內部 ADC/RX/host 及 ADC→RX 路徑已按固定時鐘條件計時並通過。
- 硬體操作未做；未下載 bit、未啟動 `hw_server`、未使用 JTAG。
