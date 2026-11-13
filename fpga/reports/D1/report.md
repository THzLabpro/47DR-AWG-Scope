# D1_TX 執行報告

## 完成檔案

- `rtl/tx/awg_tx.sv`：8 通道 TX 頂層，host/tx/dac 三域、非同步 LUTRAM FIFO、14-bit 打包、URAM 讀寫、播放器、CRC-32、underflow fault。
- `rtl/tx/awg_tx_uram_block.sv`：單一 72×4096 URAM288 推論 block；8×7 共 56 個實例。
- `sim/tx/tb_awg_tx.sv`：D1 T1–T6 單一 xsim 自檢 TB。
- `sim/tx/run.ps1`：xvlog/xelab/xsim 一鍵入口。
- `sim/tx/crc_ref.py`：Python CRC-32 參考實作。
- `build/D1/ooc.tcl`、`sim/tx/run_ooc.ps1`：xczu47dr-fsve1156-2-i OOC synth/impl 入口。
- 生成物：`build/D1/awg_tx_synth.dcp`、`build/D1/awg_tx_impl.dcp`。

## 執行命令與結果

1. `powershell.exe -NoProfile -ExecutionPolicy Bypass -File sim/tx/run.ps1`
   - xvlog：PASS
   - xelab：PASS
   - xsim：PASS
   - `RESULT name=tb_awg_tx PASS=26 FAIL=0 mismatches=0 x_count=0`
   - T6：`accepted_words=524288`，耗時 `10488480 ns`，host 接受字率 `49987033.393 words/s`。
   - CRC：RTL/SystemVerilog `D49307A0`。
2. `py -X utf8 sim/tx/crc_ref.py --channel 0 --points 131072`
   - `CRC_REF ... crc=D49307A0`，與 RTL 一致。
3. `powershell.exe -NoProfile -ExecutionPolicy Bypass -File sim/tx/run_ooc.ps1`
   - synth：PASS；impl/place/route：PASS，route 0 unrouted nets。
   - 器件：`xczu47dr-fsve1156-2-i`。
   - 時鐘：dac `612.370 MHz`、tx `306.279 MHz`、host `100 MHz`。

## 資源

依 `reports/D1/ooc_impl_utilization.rpt`：

- URAM288：`56`，符合驗收。
- RAMB36/FIFO：`0`。
- RAMB18：`0`。
- LUT：`5915`（impl report）。
- FF/CLB Registers：`21701`（impl report）。
- CDC FIFO：分散式 LUTRAM，未使用 BRAM。

## 固定驗收判定

- T1–T6：PASS。
- CRC 與 Python：PASS。
- URAM=56、TX BRAM=0：PASS。
- OOC impl 三域 WNS≥0：FAIL，需父層判斷。

實作 timing summary `reports/D1/ooc_impl_timing.rpt`：

- Overall WNS：`-4.411 ns`，TNS `-66774.812 ns`。
- Route intermediate WHS：`+0.009 ns`，THS `0.000 ns`；timing summary 的 hold 欄位在各 intra-clock path 顯示 `NA`。
- `dac_clk` intra-clock WNS：`-0.016 ns`。
- `host_clk` intra-clock WNS：`+5.406 ns`。
- `tx_clk` intra-clock WNS：`-2.190 ns`。
- `tx_clk -> dac_clk`：`+0.311 ns`。
- `tx_clk -> host_clk`：`-1.058 ns`。
- `host_clk -> tx_clk`：`-4.411 ns`，為最差路徑群組，18734 個 failing endpoints。

最差路徑位於 host/tx CDC bundled-data 與 tx_clk 寫入打包邏輯；未新增 false path、clock group 或放寬判據。依任務書規則，OOC 未收斂，狀態為 `NEEDS_PARENT_JUDGMENT`。

## 未完成與需要協調

- 正式整片時序尚未執行，D3 需在完整時鐘樹與頂層約束下重新評估。
- 目前 OOC host↔tx CDC 被 Vivado 當作一般 timing path；需要 Claude/父層決定是否改用更深的 bundled-data mailbox、加 pipeline，或在正式 CDC 結構完成後重新約束。此報告不自行添加例外。
- 未做任何硬體下載、JTAG、hw_server 或 192.168.42.x 發包。
