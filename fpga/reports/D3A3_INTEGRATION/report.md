# D3A3_INTEGRATION 執行報告

日期：2026-11-11

狀態：`NEEDS_PARENT_JUDGMENT`

## 完成檔案

- `rtl/ctrl/awg_control_v2.sv`：修正 TX_WR_DATA valid/ready 保持、STATUS 位元、CAP_RD_DATA busy SLVERR、COMMAND=32 abort、h_armed 介面，以及所有 32-bit 保留位檢查。
- `rtl/rx/awg_rx.sv`：新增 h_abort/h_armed CDC 與 abort 後重新 arm 行為。
- `rtl/top/awg_eth_top.v`：改接真實 `system_wrapper`、JTAG AXI IP、BD up_ 匯流排、兩級 SYSREF 與各時鐘域 reset_sync；刪除 `system_blackbox.v`、`jtag_axi_stub.v`、`eth_ip_stubs.v`。
- `rtl/eth/awg_eth_bridge.sv`：移除每字 payload wait、AW/W 同拍後立即等待 B、B 回應後連續啟動下一個寫字。
- `constraints/top/{cdc.tcl,timing.xdc}`：加入 D3A3 CDC/clock 關係檢查，zero-match 會報錯。
- `scripts/d3/{build_d3.tcl,run_build_d3.ps1}`：本任務重建乾淨 BD seed、make_wrapper、真實 IP 匯入、BD diff 與 `synth_design -rtl` 流程。
- `sim/d3/{tb_awg_control_v2.sv,tb_d3_system.sv}`、`sim/rx/tb_awg_rx.sv` 與執行腳本：補背壓、abort、回環模型、有限 watchdog 與 D3A3 build/report 路徑。

## 固定驗收結果

1. TX/RX：通過。
   - `powershell -NoProfile -ExecutionPolicy Bypass -File sim/d3/run_tx_rx.ps1`
   - TX：`RESULT name=tb_awg_tx PASS=26 FAIL=0 mismatches=0 x_count=0`，CRC `D49307A0`。
   - RX：`RESULT name=tb_awg_rx PASS compared=543552 mismatches=0 x_count=0 pass_items=26 fail_items=0`，abort/rearm PASS，最大 `CAP_TX_WORD` 誤差 17，限值 24。
2. 控制器單元：通過。
   - `powershell -NoProfile -ExecutionPolicy Bypass -File sim/d3/run_control_tb.ps1`
   - `RESULT name=tb_awg_control_v2 PASS=48 FAIL=0`。
3. Ethernet bridge：部分通過。
   - `powershell -NoProfile -ExecutionPolicy Bypass -File sim/eth_bridge/run.ps1 -Mode sim`
   - S1–S9 與 S11 交易檢查均產生 PASS；S10 量得 `110401` host cycles、`65536` bytes、`59.361781 MB/s`，低於固定 80 MB/s 門檻，因此 TB 以 `FAIL` 結束。
4. 系統模擬：失敗但已完成 watchdog。
   - `powershell -NoProfile -ExecutionPolicy Bypass -File sim/d3/run_system_tb.ps1`
   - `RESULT name=tb_d3_system PASS=97 FAIL=133`。
   - S7 write：`143107` cycles、`45.795104 MB/s`，高於 40 MB/s。
   - S7 read：`409682` cycles、`15.996798 MB/s`，低於 40 MB/s；CAP_RD_DATA 回讀反覆 `UDP_RX_HEADER_TIMEOUT`。
   - S3 insufficient-start/locked-length 未得到預期 AXI_ERR；S4 event capture 與 S5 manual capture 未完成。
5. 真實 BD/IP 建置：未通過。
   - BD 參數 diff 已在本任務重跑：`BD_PARAM_CHANGED 15`、`BD_PARAM_UNEXPECTED 0`。
   - 真實 `system_wrapper`、RFDC/PS BD 與 JTAG AXI IP 已被加入；`synth_design -rtl` 在 Vivado 2025.2 生成的 BD/IP 依賴檔階段失敗，最後錯誤為 generated `proc_sys_reset_v5_0_vh_rfs.vhd` 缺少 design unit `lpf`（先前同一流程亦出現 encrypted `fifo_generator`/`blk_mem_gen` envelope 錯誤）。未宣稱 synth PASS。
   - CDC Tcl 未能在成功 elaborated design 上完成命中驗收；因此沒有可報告的每條命中數。

## 跨時鐘域與保護方式

- `clk_eth ↔ host_clk`：`awg_eth_bridge` 兩個 `axis_async_fifo`。
- `host_clk ↔ tx_clk`：`awg_tx` 內部 XPM FIFO/CDC；寫資料 valid/ready 在 host 域保持。
- `host_clk ↔ rx_clk`：`awg_rx` 的 arm/abort XPM pulse、設定 array CDC、done/armed/status CDC。
- `dac_clk → rx_clk`：TX start event toggle 經 XPM single；`tx_clk → rx_clk` 的 `tx_play_word` 經 XPM handshake。
- ADC/RX 擷取記憶體：`adc_clk → rx_clk` 由兩拍資料拼接與 RX 域 BRAM 寫入，host 讀口使用既有同步讀結構。
- PL SYSREF：`pl_sysref_r → sysref_*_meta → user_sysref_*` 兩級同步。
- JTAG AXI 與 Ethernet AXI：同一 `host_clk` 下由 `axil_arb2` 單筆仲裁。

## 未完成與需要協調

- S10 仍為 59.361781 MB/s；目前 `axil_arb2` 的多狀態 AXI pipeline 仍是主要週期來源。任務歸屬不包含 `rtl/eth/axil_arb2.sv`，需要父任務決定是否擴大修改範圍。
- 系統 capture/回讀尚未完成，S3/S4/S5/S7 read 有實際失敗證據；未放寬判據或加入 false path。
- 真實 BD/IP 的 generated library 依賴仍阻塞 `synth_design -rtl`；需要父任務決定採用 Vivado project-managed IP output、固定 generated library 清單，或沿用已驗證的 D0 project IP 產物。
- 未執行 implementation、bitstream、XSA、hw_server、JTAG 或任何 `192.168.42.x` 網路操作。

## Claude 審查判定（2026-11-11）

系統模擬 133 個 FAIL 主要是 TB 本身的三個錯，RTL 基本正確。Claude 已修 `sim/d3/tb_d3_system.sv` 並重跑：

1. **status 讀錯位置**：回覆 status 在位元組 16–17（`doc/00` §4），TB 讀 18–19（err_index，恆為 0）。所以 D3A2/D3A3 所有「status=0」都沒有意義，SLVERR 也看不到。
2. **最後一拍 tkeep 錯**：`8'h1<<(n)` 只有一個位元，應為 `(8'h1<<n)-1`。奇數字數的請求（所有單字命令）長度不符，被 bridge 判 BAD_REQ，命令從未送到控制器。這就是 S2 CRC=0、S3/S4/S5 失敗的原因。
3. **TB 的 bridge `TX_FIFO_DEPTH=2048` 太小**：TX FIFO 128 bit 寬、每格只放 64 bit 酬載，深度以位元組計。256 字讀回覆需 132 格，2048 只有 128 格，整框被 `DROP_OVERSIZE_FRAME` 靜默丟掉，所以 S7 讀取全部逾時。

修正後實測：`RESULT name=tb_d3_system PASS=165 FAIL=1`。唯一失敗是 S7 讀取 31.4 MB/s（寫入 45.8 MB/s 達標）。ch1 CRC `65FFA182` 與 Python 參考值一致（ch0 期望 `9014BEF6`）。

仍需處理（D3A4）：
- **正式頂層同樣問題**：bridge `TX_FIFO_DEPTH=16384` 只有 1024 格；2048 字（`MAX_WORDS`）讀回覆需 1028 格，會被靜默丟掉。改 32768，並在 bridge 加 elaboration 檢查。
- **bridge RTL 退步**：`payload_mem` 標 `ram_style="block"`，D3A3 卻加了兩個非同步讀口（`payload_mem[exec_index>>1]`、`payload_mem[next_exec_index>>1]`），無法推成 BRAM（E1 第一輪的 Synth 8-3391 問題重現）。要改回同步讀加預取。
- 系統 TB 仍缺：S4/S5 回環逐點比對、S8 abort、S9 背壓、CRC 斷言、CAP_TX_WORD 檢查。
- 真實 BD 的 `synth_design -rtl` 被手動加入 generated 檔案的方式卡住；改用 D0 的工程模式流程。
- `create_system_v2.tcl` 把 diff 寫死到 `reports/D0/`：Claude 已改成寫在參數 dump 旁邊，並還原 D0 檔。BD diff 由 Claude 重跑，結果寫入 `reports/D3A3_INTEGRATION/bd_param_diff.txt`：changed=15、unexpected=0。
