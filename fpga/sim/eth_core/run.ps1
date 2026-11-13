$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$buildDir = Join-Path $projectRoot 'build\E2\sim'
$reportDir = Join-Path $projectRoot 'reports\E2'
. "$PSScriptRoot\..\..\scripts\xilinx_tools.ps1"; $vivadoBin = Get-VivadoBin
$xvlog = Join-Path $vivadoBin 'xvlog.bat'
$xelab = Join-Path $vivadoBin 'xelab.bat'
$xsim = Join-Path $vivadoBin 'xsim.bat'

New-Item -ItemType Directory -Force -Path $buildDir, $reportDir | Out-Null
$env:PROCESSOR_ARCHITECTURE = 'AMD64'
$env:NoDefaultCurrentDirectoryInExePath = $null
Set-Location $buildDir

function Invoke-LoggedTool {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    $logPath = Join-Path $reportDir "$Name.log"
    & $Executable @Arguments 2>&1 | Tee-Object -FilePath $logPath
    $toolExitCode = $LASTEXITCODE
    if ($toolExitCode -eq 1073741515) {
        throw "$Name returned 0xC0000135 (1073741515). Stop without retry. See $logPath"
    }
    if ($toolExitCode -ne 0) {
        throw "$Name failed with exit code $toolExitCode. See $logPath"
    }
}

$relativeSources = @(
    'rtl/eth/vendor/verilog-ethernet/lib/axis/rtl/priority_encoder.v',
    'rtl/eth/vendor/verilog-ethernet/lib/axis/rtl/arbiter.v',
    'rtl/eth/vendor/verilog-ethernet/lib/axis/rtl/axis_fifo.v',
    'rtl/eth/vendor/verilog-ethernet/rtl/lfsr.v',
    'rtl/eth/vendor/verilog-ethernet/rtl/eth_axis_rx.v',
    'rtl/eth/vendor/verilog-ethernet/rtl/eth_axis_tx.v',
    'rtl/eth/vendor/verilog-ethernet/rtl/ip_eth_rx_64.v',
    'rtl/eth/vendor/verilog-ethernet/rtl/ip_eth_tx_64.v',
    'rtl/eth/vendor/verilog-ethernet/rtl/ip_64.v',
    'rtl/eth/vendor/verilog-ethernet/rtl/ip_arb_mux.v',
    'rtl/eth/vendor/verilog-ethernet/rtl/eth_arb_mux.v',
    'rtl/eth/vendor/verilog-ethernet/rtl/arp_eth_rx.v',
    'rtl/eth/vendor/verilog-ethernet/rtl/arp_eth_tx.v',
    'rtl/eth/vendor/verilog-ethernet/rtl/arp_cache.v',
    'rtl/eth/v3_qsfp2/axis256_to_axis64.v',
    'rtl/eth/v3_qsfp2/axis64_to_axis256.v',
    'rtl/eth/v3_qsfp2/axis_eth_frame_pad_64_registered.v',
    'rtl/eth/v3_qsfp2/udp_ip_rx_64.v',
    'rtl/eth/v3_qsfp2/udp_ip_tx_64.v',
    'rtl/eth/v3_qsfp2/udp_checksum_gen_64.v',
    'rtl/eth/v3_qsfp2/udp_64.v',
    'rtl/eth/v3_qsfp2/arp.v',
    'rtl/eth/v3_qsfp2/ip_complete_64.v',
    'rtl/eth/v3_qsfp2/udp_complete_64.v',
    'rtl/eth/awg_eth_frame_pad.v',
    'rtl/eth/awg_udp_port.v',
    'sim/eth_core/tb_awg_udp_port.sv'
)
$sources = $relativeSources | ForEach-Object { Join-Path $projectRoot $_ }

Invoke-LoggedTool -Name 'E2_xvlog' -Executable $xvlog -Arguments (@('-sv', '--work', 'work') + $sources)
Invoke-LoggedTool -Name 'E2_xelab' -Executable $xelab -Arguments @('tb_awg_udp_port', '-s', 'tb_awg_udp_port_snapshot', '--debug', 'typical')
Invoke-LoggedTool -Name 'E2_xsim' -Executable $xsim -Arguments @('tb_awg_udp_port_snapshot', '-runall')

$simLog = Get-Content -LiteralPath (Join-Path $reportDir 'E2_xsim.log') -Raw
$requiredResults = @(
    'RESULT name=T1 PASS', 'RESULT name=T2 PASS', 'RESULT name=T3 PASS',
    'RESULT name=T4 PASS', 'RESULT name=T5 PASS', 'RESULT name=T6 PASS',
    'RESULT name=tb_awg_udp_port PASS'
)
foreach ($result in $requiredResults) {
    if (-not $simLog.Contains($result)) {
        throw "Missing acceptance result '$result' in E2_xsim.log"
    }
}

Write-Output "E2 xsim acceptance PASS; logs: $reportDir"
