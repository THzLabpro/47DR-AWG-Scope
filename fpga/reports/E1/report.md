# E1_BRIDGE 執行報告

狀態：`NEEDS_PARENT_JUDGMENT`。S11 的 JTAG master 寫請求仍超時；bridge OOC 綜合也因封包記憶體 RAM 推導失敗而停止。依工程規則，不再重試這兩項相同失敗。

## 完成檔案

- `rtl/eth/awg_eth_bridge.sv`：UDP app bridge、兩個 async frame FIFO、封包檢查、AXI4-Lite 單筆命令引擎、INFO/PING、WRITE 去重、計數器、READ 結果緩衝及 TX 回覆。
- `rtl/eth/axil_arb2.sv`：JTAG/Ethernet AXI4-Lite 雙 master 仲裁器。
- `sim/eth_bridge/tb_eth_bridge.sv`：S1–S11 整鏈 xsim testbench，含 v1 `awg_subsystem`、`adc_capture`、RFDC 模型及簡易 JTAG master。
- `sim/eth_bridge/run.ps1`、`sim/eth_bridge/ooc.tcl`、`sim/eth_bridge/tb_eth_bridge.wcfg`。
- 本報告、`status.json` 及下列執行日誌。

## 執行與結果

- `xvlog` 2025.2：E1 bridge、arbiter、async FIFO、v1 RTL 和 TB 均成功分析；0 error、0 warning。日誌：`build/E1/xvlog/full.log`。
- `xelab` 2025.2：`tb_eth_bridge` 成功 elaboration。日誌：`build/E1/xsim/full_xelab.log`。
- 完整 S1–S10 run：S1、S2、S3、S4、S5、S7、S8 產生 PASS；S6 擷取完成及讀取成功，但舊版 TB 樣點比對在 CH0 word 1 報 mismatch；S9 只檢查無死鎖，未驗證丟包計數、回覆 seq 唯一性和每筆成功資料；S10 量得 `51902` 個 host_clk 週期、`65536` bytes、`126.268737 MB/s`。日誌：`reports/E1/full_xsim.log`。
- S2 獨立 run：32 個封包的 CH0/CH7 寫入與讀回逐字比對，`PASS=35 FAIL=0`。日誌：`build/E1/xsim/s2.log`。
- S3 獨立 run：2048 字 WRITE/READ，`PASS=38 FAIL=0`。日誌：`build/E1/xsim/s3.log`。
- S6 後續將 TB sample index 改成依 16-bit sample packing 逐字對應；修改後沒有重新執行 S6，因此 S6 最終狀態為未驗證。
- S11 run：三個 Ethernet 寫請求回覆成功後，JTAG 寫 `0x9020000C` request watchdog 逾時，當時 `aw_done=0`、`w_done=0`、`s0_aw_hold=0`、`s0_w_hold=0`、JTAG `bvalid=1`、`rvalid=1`。已嘗試兩輪 driver handshake 修正，仍重現；日誌：`build/E1/xsim/s11.log`。
- OOC 綜合：bridge 綜合失敗，`Synth 8-3391` 無法推導 65,728-bit `packet_mem` RAM，解散成暫存器亦超過工具限制。統計為 2 errors、13 warnings、0 critical warnings。因腳本在 bridge 失敗退出，`axil_arb2` OOC 未執行；兩者 WNS、資源和 CDC 報告均未取得。日誌：`reports/E1/ooc.log`。

## 未完成與需協調

- 需重構 `packet_mem` 的寫入/讀取模式，使 Vivado 可推導同步讀 RAM；目前每個 64-bit RX beat 以迴圈分成多個動態 byte 寫入，導致多寫埠推導失敗。不可用放寬判據或時序例外替代修正。
- S11 需要重新檢查 TB JTAG master 與 arbiter ready/valid 的取樣時序，再完成固定並行仲裁驗收；本輪停止於 watchdog 失敗。
- S6 需在已修正 TB sample index 後重新執行。S9 需補上固定清單要求的 dropped counter、不同 seq 回覆與成功寫入資料檢查，現有場景只驗證了不死鎖。
- 需在 bridge RAM 修復後順序執行兩個 OOC 綜合，取得 LUT/FF/BRAM/URAM、WNS 與 CDC 結果。現有 OOC 報告沒有足夠證據判定 CDC 約束通過。
- 未操作硬體、JTAG、hw_server 或 `192.168.42.x` 網路。

Vivado/xsim 曾將 snapshot 建在工程根目錄 `xsim.dir`；目錄中另有其他任務的 `tb_awg_tx_sim`，因此未清理該共用目錄，避免刪除其他任務產物。
