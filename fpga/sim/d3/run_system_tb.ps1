param([string]$TestPlusarg = '')
$ErrorActionPreference = 'Stop'
$env:PROCESSOR_ARCHITECTURE = 'AMD64'
$env:NoDefaultCurrentDirectoryInExePath = $null
$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. "$PSScriptRoot\..\..\scripts\xilinx_tools.ps1"; $vivado = Get-VivadoBin
$build = Join-Path $root 'build\D3C_IMPL\sim_system'
$report = Join-Path $root 'reports\D3C_IMPL\system_tb'
New-Item -ItemType Directory -Force -Path $build, $report | Out-Null
Push-Location $build
try {
    $glbl = Join-Path $vivado '..\data\verilog\src\glbl.v'
    $sources = @(
        (Join-Path $root 'rtl\eth\vendor\verilog-ethernet\lib\axis\rtl\axis_async_fifo.v'),
        (Join-Path $root 'rtl\eth\awg_eth_bridge.sv'),
        (Join-Path $root 'rtl\eth\axil_arb2.sv'),
        (Join-Path $root 'rtl\ctrl\awg_control_v2.sv'),
        (Join-Path $root 'rtl\tx\awg_tx_uram_block.sv'),
        (Join-Path $root 'rtl\tx\awg_tx.sv'),
        (Join-Path $root 'rtl\rx\awg_rx.sv'),
        (Join-Path $root 'sim\d3\tb_d3_system.sv'),
        $glbl
    )
    & (Join-Path $vivado 'xvlog.bat') -sv -L xpm @sources -nolog -log (Join-Path $report 'system_xvlog.log') 2>&1 | Tee-Object -FilePath (Join-Path $report 'system_xvlog_console.log')
    if ($LASTEXITCODE -eq -1073741515 -or $LASTEXITCODE -eq 1073741515) { throw 'xvlog returned 0xC0000135 (1073741515); stopping without retry.' }
    if ($LASTEXITCODE -ne 0) { throw "system xvlog failed: $LASTEXITCODE" }
    & (Join-Path $vivado 'xelab.bat') -L xpm work.tb_d3_system work.glbl -s tb_d3_system_sim -debug typical -nolog -log (Join-Path $report 'system_xelab.log') 2>&1 | Tee-Object -FilePath (Join-Path $report 'system_xelab_console.log')
    if ($LASTEXITCODE -eq -1073741515 -or $LASTEXITCODE -eq 1073741515) { throw 'xelab returned 0xC0000135 (1073741515); stopping without retry.' }
    if ($LASTEXITCODE -ne 0) { throw "system xelab failed: $LASTEXITCODE" }
    $simArgs = @('tb_d3_system_sim')
    if ($TestPlusarg) { $simArgs += @('--testplusarg', $TestPlusarg) }
    $simArgs += @('-runall','-nolog')
    & (Join-Path $vivado 'xsim.bat') @simArgs 2>&1 | Tee-Object -FilePath (Join-Path $report 'system_xsim.log')
    if ($LASTEXITCODE -ne 0) { throw "system xsim failed: $LASTEXITCODE" }
    $result = Select-String -Path (Join-Path $report 'system_xsim.log') -Pattern '^RESULT name=tb_d3_system '
    if (-not $result) { throw 'system TB missing RESULT line' }
    $result.Line
    if ($result.Line -notmatch 'FAIL=0') { throw "system TB failed: $($result.Line)" }
} finally { Pop-Location }
