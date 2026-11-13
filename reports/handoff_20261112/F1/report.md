# F1 — 初始化韌體改 9.8 GS/s、從新 XSA 重建 BSP 與 ELF

結論：**PASS（建置）**。ELF 已從 D3B 的 XSA 建出，並打包成 `scripts/program.tcl -package` 可用的套件。上板未做，E5 需使用者同意。執行者是 Claude，全程沒有硬體操作。

## 改了什麼

### 速率與訊息（`software/src/main.c`、`devices/spi_ctrl.c`）

| 項目 | 舊 | 新 |
|---|---|---|
| `DAC_EXPECTED_RATE_GSPS` | 9.0 | 9.8 |
| `DAC_FABRIC_CLOCK_HZ` | 562500000 | 612500000 |
| 速率檢查訊息 | DAC 9 GSPS | DAC 9.8 GSPS |
| AWG READY | DAC=9000000000 | DAC=9800000000 |
| 結尾提示 | load wave RAM and START using JTAG | load waveforms and START over QSFP2 40GbE (UDP 9100) |
| 每秒溫度行 | AWG controlled over JTAG | AWG controlled over 40GbE |
| SYSREF 註解 | 562.5 MHz (1350) | 612.5 MHz (1470)（416.667 kHz 可整除） |

`AXI_REG_WRITE(up_axi, 4*4, DAC_FABRIC_CLOCK_HZ/4)` 寫的是 `user_control` 的 `clock_1pps`，不是 v2 控制器 0x9020_0000 的 TX_MASK（兩者基址不同），所以不受影響。

### SDT BSP 相容（`#ifdef SDT`，舊 BSP 的寫法保留在 `#else`）

- `parameters.h`：新增 `*_LOOKUP_KEY`。SDT 下用 base address（`XPAR_XSPIPS_0/XGPIOPS_0/XIICPS_0_BASEADDR`，位址與舊的 SPI1、GPIO、I2C1 相同），舊 BSP 下用 device ID。
- `spi_init`、`gpio_init`、`iic_init`、`xadc_initial`、`RFdcDcp_initial` 的參數改成 `UINTPTR` lookup key。
- `main.c`：SDT 下 RFDC 用 `XPAR_XRFDC_0_BASEADDR`、AMS 用 `XPAR_XSYSMONPSU_0_BASEADDR`；`xtime_l.h` 改成 `xiltimer.h`。
- `init_trace.c`：
  - SDT 的 libxil 把 `outbyte`、`inbyte`、`XUartPs_SendByte` 放在同一個 `xuartps_hw.c.obj`，和本檔自訂、會記錄開機訊息的 `outbyte` 衝突。
  - 改用 `xuartps_hw.h` 的暫存器巨集送字元（與 `XUartPs_SendByte` 相同），並自行提供 `inbyte`（與 `XUartPs_RecvByte` 相同）。這樣 libxil 的那個 obj 不會被連結進來。

### 建置腳本（新增 `software/build/`）

- `build_vitis_bsp.py`：從 `rf_udp_link_v3/firmware/build_vitis.py` 複製（唯讀來源），沿用其 cp936 修正。
- `build_fw.ps1`：
  1. 用 Vitis 2025.2 從 XSA 建 SDT standalone BSP（psu_cortexa53_0，libmetal 由 RFDC 驅動自動帶入）；
  2. 編譯 `software/src/**/*.c`，旗標同舊的 `build_software.ps1`（`-O0 -g3`），另加 `-DSDT -DXLNX_PLATFORM -specs=Xilinx.spec`；
  3. 用原本的 `lscript.ld` 連結（DDR 0x0）；
  4. 打包。
- 舊的 `scripts/build_software.ps1` 依賴舊 XSA 的參考 BSP，不適用 v2，保留不動。

## 結果

- BSP：Vitis 建置成功（`build/F1/bsp/vitis.log`）。RFDC 設定表 `xrfdc_g.c` 與 doc/01 一致：
  - DAC tile 2 PLL 開啟：200 MHz × 49 = 9.8 GS/s，fabric 612.5 MHz；其他 DAC tile 由 tile 2 分配時鐘。
  - DAC 資料寬度 16、interpolation 1。
  - ADC 5.0 GS/s，fabric 416.667 MHz，資料寬度 12，decimation 1。
- 編譯：0 error。唯一 warning 是 `rfsoc_cfg.c:133` 未使用的變數（`ChangeSampleFreq` 沒有被呼叫，屬於既有程式碼）。
- ELF：text 289888、data 9212、bss 94944，單一 LOAD 段在 0x0（DDR）。
- 已核對 ELF 內容：
  - `XSpiPs_CfgInitialize`、`XGpioPs_CfgInitialize`、`XRFdc_CfgInitialize` 都在，SPI/RFDC 初始化沒有被條件編譯排除。
  - `.drvcfg_sec`（`XRFdc_ConfigTable` 等）已連結。
  - `outbyte`、`inbyte` 是本工程的版本。
  - 字串含 `DAC=9800000000`、`DAC 9.8 GSPS`、`over QSFP2 40GbE`。
- ELF 內嵌 `__TIME__`/`__DATE__`，所以每次建置的 sha256 都不同。以 `build/F1/artifacts.txt` 為準。

## 上板套件 `build/F1/package/`（`program.tcl -package build/F1/package`）

| 檔案 | 來源 | sha256 |
|---|---|---|
| `rf_awg_scope_v1.bit` | XSA 內的 `awg_eth_v2.bit`（program.tcl 寫死此檔名） | `F9DC6624…5BE638`（與 D3B 相同） |
| `psu_init.tcl` | XSA | `26704CA3…BDC988` |
| `rf_awg_init.elf` | 本次建置 | 見 artifacts.txt |
| `init_protocol.txt` | ELF 符號 | `awg_clock_ready 0x5b140`、`awg_pl_program_ack 0x5b180`、`awg_init_log 0x4b0c0`、`awg_init_log_length 0x5b0c0`、`init_stage_debug 0x5b100` |

program.tcl 的流程（psu_init → dow ELF → 等 CLK1 → fpga → ack）不用改。

## 未驗證／風險

- 沒有上板。SDT ELF 能在板上跑到 `main`，是依據 v3 的經驗（XSCT ELF 曾卡在 `_startup`，SDT 版正常），本工程尚未實測。
- RFDC 驅動換成 2025.2 SDT 版。MTS（`RFdcDcp_Example`）和 PLL 回讀檢查要等 E5 上板才能確認。
- E5 上板需使用者明確同意。
