# Codex 工作規則（rf_awg_eth_v1）

本工程 = `../rf_awg_scope_v1`（47DR AWG/Scope，JTAG 傳資料）改成走 QSFP2 40GbE 光口。
Claude 負責總體設計和審查；執行者（Codex）按 `codex/<任務>.md` 執行；Claude 審查後提交。

## 必讀（每個任務開始前）

- `doc/00_ETH_PLAN.md`：目標、架構、**凍結的介面與封包格式（§4）**、任務分解
- 目前任務書 `codex/<任務>.md`
- 寫 RTL/TB 時：`D:/ClaudeProject/rf_udp_link_v3/doc/02_CODING_STYLE.md`（唯讀參考）

## 硬性規則

1. **只寫 `D:\ClaudeProject\47DR_DAAD\rf_awg_eth_v1` 內任務書列出的歸屬檔案或目錄**。
   - 唯讀：`../rf_awg_scope_v1`、`D:\ClaudeProject\rf_udp_link_v3`、`D:\ClaudeProject\verilog-ethernet`，以及本工程中不屬於你的檔案。
   - 同一批任務並行執行，不准碰別人的歸屬檔案。
   - `AGENTS.md`、`doc/00_ETH_PLAN.md`、`doc/01_DATAPATH_V2.md`、`codex/`、`scripts/codex/` 由 Claude 維護，Codex 不准改。
   - 本工程 `rtl/` 下沿用 v1 的檔案（`awg_*.sv`、`adc_capture.sv`、`adaloop_top.v` 等）和 `rtl/eth/v3_qsfp2/`、`rtl/eth/vendor/` 唯讀；需要改時寫在報告的「需要協調」。
2. 不要執行 `git commit/reset/checkout --/clean/stash`。
3. Python：`py -X utf8 ...`（3.12）；禁止裸 `python`（會指到 Vivado 內建、已損壞的 python）。
   MATLAB：`"D:\Program Files\MATLAB\R2023b\bin\matlab.exe" -batch "..."`。
4. Vivado 2025.2：`D:\AMDDesignTools\2025.2\Vivado\bin\`。
   - 啟動前在 PowerShell 設 `$env:PROCESSOR_ARCHITECTURE='AMD64'`，並 `$env:NoDefaultCurrentDirectoryInExePath=$null`。
   - 如果 Vivado、xvlog 回傳 0xC0000135（1073741515），立刻停下並在報告寫明，不要重試超過 2 次。
   - 生成物放 `build/<任務>/`，日誌和結論放 `reports/<任務>/`。
5. 模擬：xsim 2025.2 的 `--testplusarg` 不能帶前導 `+`。同一個 TB 不准同時開兩個 run。
6. 不得對硬體做任何操作（下載 bit、hw_server、JTAG、對 192.168.42.x 發包）。主機軟體測試只能用 127.0.0.1 上的模擬器。
7. 不得用沒有依據的 false_path、clock_groups 或放寬判據來「通過」；失敗就如實報告。
8. 凍結項：`doc/00_ETH_PLAN.md` §3、§4 的網路參數、介面和封包格式；v1 的 AXI4-Lite 地址表。
9. 防返工：驗收清單固定，不自行擴展；同一個失敗最多修 2 輪，仍失敗就停止，報告 `NEEDS_PARENT_JUDGMENT`。
10. 長任務一次阻塞等待，不要輪詢；大日誌只看 tail 或 grep。
11. **不准編造結果**。每個數字都要能從 `reports/<任務>/` 的日誌或腳本輸出找到；沒做的寫「未做」。
12. 多開 CPU：本機 20 邏輯核、32 GB。Vivado 腳本開頭加 `set_param general.maxThreads 20`。
    **同時最多 3 個 Vivado 行程**（多個任務並行）：啟動綜合/impl 前用 PowerShell `(Get-Process vivado -ErrorAction SilentlyContinue).Count` 檢查，≥ 3 就在同一個指令內每 60 s 再查一次直到 < 3。xsim/xvlog 不受此限。
13. 資料路徑規格 `doc/01_DATAPATH_V2.md` 凍結（D 系列任務和 E3 必讀）。

## 最終報告

寫到 `reports/<任務>/report.md` 和 `status.json`，並作為最後一則訊息，內容包括：

- 完成了什麼（檔案清單）
- 執行過的命令和實際結果（PASS/FAIL 計數、關鍵數字）
- 未完成或失敗的項目及原因
- 規範歧義、需要協調的事項

報告用繁體中文。最後一則訊息以 `CODEX_TASK_DONE <任務名> <PASS|FAIL|NEEDS_PARENT_JUDGMENT>` 開頭。
