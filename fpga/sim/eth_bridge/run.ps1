param(
    [ValidateSet('all', 'sim', 'ooc')]
    [string]$Mode = 'all'
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. "$PSScriptRoot\..\..\scripts\xilinx_tools.ps1"; $vivado = Get-VivadoBin
$env:PROCESSOR_ARCHITECTURE = 'AMD64'
$env:NoDefaultCurrentDirectoryInExePath = $null
$build = Join-Path $repo 'build/D3A4_INTEGRATION/eth_bridge'
$reports = Join-Path $repo 'reports/D3A4_INTEGRATION/eth_bridge'
New-Item -ItemType Directory -Force -Path $build, $reports, (Join-Path $build 'xsim'), (Join-Path $build 'ooc') | Out-Null

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
) | ForEach-Object { Join-Path $repo $_ }

if ($Mode -eq 'all' -or $Mode -eq 'sim') {
    Push-Location (Join-Path $build 'xsim')
    try {
        & (Join-Path $vivado 'xvlog.bat') --sv --nolog -work xil_defaultlib @rtl 2>&1 |
            Tee-Object -FilePath (Join-Path $reports 'xvlog.log')
        if ($LASTEXITCODE -ne 0) { throw "xvlog failed: $LASTEXITCODE" }
        & (Join-Path $vivado 'xelab.bat') xil_defaultlib.tb_eth_bridge -s tb_eth_bridge_d3a4 -debug typical -nolog 2>&1 |
            Tee-Object -FilePath (Join-Path $reports 'xelab.log')
        if ($LASTEXITCODE -ne 0) { throw "xelab failed: $LASTEXITCODE" }
        & (Join-Path $vivado 'xsim.bat') tb_eth_bridge_d3a4 -runall -nolog 2>&1 |
            Tee-Object -FilePath (Join-Path $reports 'xsim.log')
        if ($LASTEXITCODE -ne 0) { throw "xsim failed: $LASTEXITCODE" }
        $sim_log = Get-Content -Raw (Join-Path $reports 'xsim.log')
        if ($sim_log -notmatch 'RESULT name=tb_eth_bridge PASS=\d+ FAIL=0') {
            throw 'xsim completed without a zero-failure D3A4 RESULT line'
        }
    } finally {
        Pop-Location
    }
}

if ($Mode -eq 'all' -or $Mode -eq 'ooc') {
    $vivado_count = @(Get-Process vivado -ErrorAction SilentlyContinue).Count
    while ($vivado_count -ge 3) {
        Start-Sleep -Seconds 60
        $vivado_count = @(Get-Process vivado -ErrorAction SilentlyContinue).Count
    }
    Push-Location $repo
    try {
        & (Join-Path $vivado 'vivado.bat') -mode batch -nojournal -nolog `
            -source sim/eth_bridge/ooc.tcl -tclargs $repo $build $reports 2>&1 |
            Tee-Object -FilePath (Join-Path $reports 'ooc.log')
        if ($LASTEXITCODE -ne 0) { throw "OOC synthesis/implementation failed: $LASTEXITCODE" }
    } finally {
        Pop-Location
    }
}
