$ErrorActionPreference = 'Stop'
$env:PROCESSOR_ARCHITECTURE = 'AMD64'
$env:NoDefaultCurrentDirectoryInExePath = $null
$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. "$PSScriptRoot\..\xilinx_tools.ps1"; $vivado = Get-VivadoBin
$build = Join-Path $root 'build\D3C_IMPL\eth_bridge'
$report = Join-Path $root 'reports\D3C_IMPL\eth_bridge'
New-Item -ItemType Directory -Force -Path $build, $report | Out-Null

function Invoke-Tool([string]$name, [string]$exe, [string[]]$toolArgs, [string]$log) {
    "COMMAND $name $($toolArgs -join ' ')" | Tee-Object -FilePath $log -Append
    & $exe @toolArgs 2>&1 | Tee-Object -FilePath $log -Append
    $code = $LASTEXITCODE
    "EXIT_CODE $name $code" | Tee-Object -FilePath $log -Append
    if ($code -eq -1073741515 -or $code -eq 1073741515) {
        throw "$name returned 0xC0000135 (1073741515); stopping without retry."
    }
    if ($code -ne 0) { throw "$name failed with exit code $code" }
}

$rtl = @(
    'rtl/eth/vendor/verilog-ethernet/lib/axis/rtl/axis_async_fifo.v',
    'rtl/eth/awg_eth_bridge.sv',
    'rtl/eth/axil_arb2.sv',
    'rtl/awg_wave_bank.sv',
    'rtl/axis_wide_gearbox.sv',
    'rtl/axis_register_slice.sv',
    'rtl/awg_player.sv',
    'rtl/awg_control.sv',
    'rtl/awg_subsystem.sv',
    'rtl/adc_capture.sv',
    'sim/eth_bridge/tb_eth_bridge.sv'
) | ForEach-Object { Join-Path $root $_ }

Push-Location $build
try {
    $xvlog = Join-Path $report 'xvlog.log'
    $xelab = Join-Path $report 'xelab.log'
    $xsim = Join-Path $report 'xsim.log'
    Remove-Item -LiteralPath $xvlog, $xelab, $xsim -Force -ErrorAction SilentlyContinue

    Invoke-Tool 'xvlog_eth_bridge' (Join-Path $vivado 'xvlog.bat') `
        (@('--sv', '--nolog', '-work', 'xil_defaultlib') + $rtl) $xvlog
    Invoke-Tool 'xelab_eth_bridge' (Join-Path $vivado 'xelab.bat') `
        @('xil_defaultlib.tb_eth_bridge', '-s', 'tb_eth_bridge_d3c', '-debug', 'typical', '-nolog') $xelab
    Invoke-Tool 'xsim_eth_bridge' (Join-Path $vivado 'xsim.bat') `
        @('tb_eth_bridge_d3c', '-runall', '-nolog') $xsim

    $result = Select-String -Path $xsim -Pattern '^RESULT name=tb_eth_bridge '
    if (-not $result) { throw 'Ethernet bridge simulation missing RESULT line' }
    $result.Line
    if ($result.Line -notmatch 'FAIL=0') { throw "Ethernet bridge simulation failed: $($result.Line)" }
} finally {
    Pop-Location
}
