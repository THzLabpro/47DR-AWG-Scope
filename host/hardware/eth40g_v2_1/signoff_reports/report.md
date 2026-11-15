# V2.1 — 修正 E6 問題、發端池化、收端 ≥ 2 倍發端時長（doc/04）

日期：2026-11-13。執行者：Claude（未使用 Codex）。結論：**上板前的工作全部完成**，尚未下載到板上。上板需使用者同意。

## RTL 修改

| 檔案 | 修改 |
|---|---|
| `rtl/eth/awg_udp_port.v` | **R2**：新增 `udp_rx_payload_active`，上一包 payload 結束前不接受新表頭，表頭被接收前不放行 payload。根因：udp_complete_64 的表頭和 payload 分兩條通道，app 忙時下一包的 payload 走路由 0 被丟掉，app 把表頭配到下一包的 payload，awg_bulk 停在 ST_HDR_0，之後所有封包都被擋住 |
| `rtl/ctrl/awg_control_v2.sv` | **R1**：刪除只累計 V1 寫入的 `start_counts_ok`；STATUS `[9]` start_rejected、`[10]` started；TX_MODE（0x64）；TX_LENGTH 加寬到 16 bit；TX_WR_CH 槽位 ≥ N 時回 SLVERR；TX_WR_PTR 加寬到 21 bit、CAP_TX_WORD 加寬到 15 bit；ABI `0x00050000` |
| `rtl/tx/awg_tx.sv` | 發端池化：槽位 s 的邏輯行 L → bank s×(8/N)+L[14:12]，套用在 V1 寫入、bulk 寫入、CRC、播放（每個 DAC 通道一級 8:1 bank 選擇）；改變 log2N 時各槽位的寫入計數歸零；TX_MODE mailbox；START 參數和 bulk 計數比較提前一拍暫存（時序）；`tx_running_q` 加 KEEP（避免被合併後 CDC 約束找不到） |
| `rtl/eth/awg_bulk.sv` | TXW 行號加寬到 15 bit，範圍上限 524,288 對 |
| `rtl/rx/awg_rx.sv`、`rtl/top/awg_eth_top.v` | 15 bit 的 tx_play_word、新埠；BUILD_ID `0xD4B0_2026` |
| `constraints/top/v2s_cdc.tcl` | 新增 `mode_host_to_tx`（max_delay + bus skew，比照 length/mask） |

## 模擬

| 項目 | 結果 |
|---|---|
| `sim/v21/tb_v21_rxr_frames`（新，frame 層級 udp_port + awg_bulk） | T1～T4 全部 PASS：連送 8 個 RXR；RXR 與 9100 交錯；與會被丟棄的 9200 封包交錯。修正前在 T2 重現了板上的現象 |
| 系統 TB `tb_v2s_system` | **342 / 0**。新增 S15：1 槽位 4224 字跨 bank、2 槽位跨 bank，CRC 正確，DAC 輸出逐點比對連續（跨 bank、回繞），TX_WR_PTR=135168；換模式後 START 被拒（STATUS[9]）。S10 改成 bulk 全長寫入後直接 START（不再用 V1 填計數） |
| bulk | 2652 / 0 |
| V1 tx | 70 / 0 |
| control | 76 / 0 |
| udp_port | PASS |
| RX D64 | **未完成**：R1 PASS 後卡在 R4 的 `wait (dut.state == 2'd3)`（沒有逾時），跑了 19 小時後停止。V2.1 之前的基準（V2R_RXMEM）同樣停在 R1，屬於既有的 TB 問題，不是 V2.1 回歸；awg_rx 這次只加寬了 tx_play_word。系統 TB 已涵蓋 RX |
| 主機 pytest | 49 項全過（新增 `test_v21_host.py` 5 項）。原本誤寫為 54，已於 11-13 更正 |

DAC 輸出比預期起點晚一個字（32 點）：tx→dac 的 word_valid 比資料晚一拍，所以第一個送出的是第 1 字。這是 V1 起就有的固定對齊，之後是連續循環；原本的 TB 用搜尋偏移比對，所以沒有發現。

## 綜合與實現（`build/V21_IMPL`）

- 綜合（第 4 次）：methodology 的類別與數量和 V2S_R3 完全相同；tx_clk 估計 +0.388 ns（START 時序修正前是 +0.192）。
- 前 3 次綜合失敗都和設計無關：
  1. 第 1 次被我中途停掉，留下建到一半的專案；
  2. Vivado 報 `[Common 17-1257] Failed to create directory 'C'`。綜合本身完成並寫出了 checkpoint。建置腳本**只排除這一個 ID**，其他 ERROR 仍判失敗；
  3. `tx_running_q` 被合併掉，CDC 約束找不到來源，已加 KEEP 屬性。

### 佈局佈線：第 1 種策略就收斂

| 項目 | 結果 |
|---|---|
| WNS / TNS | +0.072 ns / 0 |
| WHS / THS | +0.010 ns / 0 |
| WPWS | +0.033 ns |
| 未佈線 / 佈線錯誤 | 0 / 0 |
| DRC 錯誤 | 0 |
| bus skew | 44 條全部達標（V2S_R3 是 43 條，多出的是 mode），最小 slack 1.855 ns |
| methodology（佈線後） | 與 V2S_R3 完全相同：TIMING-54 1、LUTAR-1 15、TIMING-24 10、TIMING-9/10/18 |
| 資源 | LUT 55,612（13.1%）、BRAM tile 803.5/1080、URAM 56/80 |
| 約束命中 | 與 V2S_R3 逐行比對：只多出 length 13→16 bit 和 mode（26 個 destination） |

### report_cdc：1 筆 CDC-1 Critical，判定為既有、可接受

- 位置：`eth_bridge_i/u_tx_fifo/s_rst_sync1_reg` → `s_rst_sync2_reg`。這是 verilog-ethernet `axis_async_fifo` 的兩級 reset 同步器，RTL 沒有 ASYNC_REG，屬於唯讀的 vendor 程式碼，沒有修改。
- report_cdc 對它的分類會隨佈局變動：D3C（已交付的 V1）是 CDC-1，V2S_R3 是 CDC-2，這次是 CDC-1。V2S_R3 的 CDC-2 有 9 筆，這次 8 筆，正好就是這一筆被改歸類。

### 判定為可接受的事項

- bulk 寫入計數比較改為暫存後再用，使「bulk 資料和 START 同時到達」的理論競爭窗口多了一拍。主機一定在收到最後一包 TXW 的 ACK（往返數十 µs）之後才送 START，實際上不會發生。

## 產物

- `build/V21_IMPL/awg_eth_v2.bit`：22,762,127 B，sha256 B7470AC9DA3CCF11E3AD0DACF6C0092BAD546223FCD71B1962BD2F1AAC5A1FDF
- `build/V21_IMPL/awg_eth_v2.xsa`：4,746,372 B，sha256 9E55ED31AD0C83238A6E6C66846170971EDBA468D2A35EC5892A61E9EB015E4D
- F3 韌體（`build/F3/package`，`program.tcl -package` 用的格式）：
  - ELF sha256 A572B927…0500B2；
  - `psu_init.tcl` 的 sha256 與 F1/F2 相同；
  - `init_protocol.txt` 與 F2 完全相同；
  - `F3_FIRMWARE_BUILD_PASS`。

## 主機端

- `awg.py`：
  - 依啟用的通道數自動選 N（`pool_slots`），設定 TX_MODE，下載到槽位 0..n-1；
  - `max_tx_samples`、`tx_limit_for_capture`、`capture_samples_for_tx`（擷取 ≥ 2 倍發端週期）；
  - START 被拒（STATUS[9]）時拋出錯誤；
  - 新 bit 恢復 RXR window=8；D4A0 bit 仍保留繞道（9100 下載、window=1）。
- `fpga_emu.py`：abi=3 = V2.1 行為。GUI 的 `--emulator` 改用 abi=3。
- GUI：
  - 發端長度上限隨發端通道數和「收端 2 倍」規則變化；
  - 下載後自動把擷取長度設成 ≥ 2 倍發端週期。
- 上板腳本 `scripts/e7/e7_v21_board_test.py`：已在模擬器上跑完整流程，尚未上板。

## 未做

- 上板測試（需使用者同意）。
- RX D64 TB 卡在 R4（既有問題，見上表），沒有修正。
