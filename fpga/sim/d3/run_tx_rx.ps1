$ErrorActionPreference = 'Stop'
$env:PROCESSOR_ARCHITECTURE = 'AMD64'
$env:NoDefaultCurrentDirectoryInExePath = $null
$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. "$PSScriptRoot\..\..\scripts\xilinx_tools.ps1"; $vivado = Get-VivadoBin
$buildRoot = Join-Path $root 'build\D3C_IMPL'
$reportRoot = Join-Path $root 'reports\D3C_IMPL\tx_rx'
New-Item -ItemType Directory -Force -Path $buildRoot, $reportRoot, (Join-Path $buildRoot 'sim_tx'), (Join-Path $buildRoot 'sim_rx') | Out-Null

function Invoke-Tool([string]$name, [string]$exe, [string[]]$toolArgs, [string]$log) {
    "COMMAND $name $($toolArgs -join ' ')" | Tee-Object -FilePath $log -Append
    & $exe @toolArgs 2>&1 | Tee-Object -FilePath $log -Append
    $code = $LASTEXITCODE
    "EXIT_CODE $name $code" | Tee-Object -FilePath $log -Append
    if ($code -eq -1073741515 -or $code -eq 1073741515) { throw "$name returned 0xC0000135 (1073741515); stopping without retry." }
    if ($code -ne 0) { throw "$name failed with exit code $code" }
}

$txDir = Join-Path $buildRoot 'sim_tx'
Push-Location $txDir
try {
    $xv = Join-Path $reportRoot 'tx_xvlog.log'; $xe = Join-Path $reportRoot 'tx_xelab.log'; $xs = Join-Path $reportRoot 'tx_xsim.log'
    Remove-Item -LiteralPath $xv,$xe,$xs -Force -ErrorAction SilentlyContinue
    $glbl = Join-Path $vivado '..\data\verilog\src\glbl.v'
    Invoke-Tool 'xvlog_tx' (Join-Path $vivado 'xvlog.bat') @('-sv','-L','xpm',(Join-Path $root 'rtl\tx\awg_tx_uram_block.sv'),(Join-Path $root 'rtl\tx\awg_tx.sv'),(Join-Path $root 'sim\tx\tb_awg_tx.sv'),$glbl) $xv
    Invoke-Tool 'xelab_tx' (Join-Path $vivado 'xelab.bat') @('-L','xpm','work.tb_awg_tx','work.glbl','-s','tb_awg_tx_d3c','-debug','typical') $xe
    Invoke-Tool 'xsim_tx' (Join-Path $vivado 'xsim.bat') @('tb_awg_tx_d3c','-runall') $xs
    $line = Select-String -Path $xs -Pattern '^RESULT name=tb_awg_tx ' | Select-Object -Last 1
    if (-not $line) { throw 'TX RESULT missing' }; $line.Line
    if ($line.Line -notmatch 'FAIL=0' -or $line.Line -notmatch 'mismatches=0') { throw "TX TB failed: $($line.Line)" }
} finally { Pop-Location }

$rxDir = Join-Path $buildRoot 'sim_rx'
Push-Location $rxDir
try {
    $xv = Join-Path $reportRoot 'rx_xvlog.log'; $xe = Join-Path $reportRoot 'rx_xelab.log'; $xs = Join-Path $reportRoot 'rx_xsim.log'
    Remove-Item -LiteralPath $xv,$xe,$xs -Force -ErrorAction SilentlyContinue
    $glbl = Join-Path $vivado '..\data\verilog\src\glbl.v'
    Invoke-Tool 'xvlog_rx' (Join-Path $vivado 'xvlog.bat') @('-sv','-L','xpm',(Join-Path $root 'rtl\rx\awg_rx.sv'),(Join-Path $root 'sim\rx\tb_awg_rx.sv'),$glbl) $xv
    Invoke-Tool 'xelab_rx' (Join-Path $vivado 'xelab.bat') @('-L','xpm','work.tb_awg_rx','work.glbl','-s','tb_awg_rx_d3c','-debug','typical') $xe
    Invoke-Tool 'xsim_rx' (Join-Path $vivado 'xsim.bat') @('tb_awg_rx_d3c','-runall') $xs
    $line = Select-String -Path $xs -Pattern '^RESULT name=tb_awg_rx ' | Select-Object -Last 1
    if (-not $line) { throw 'RX RESULT missing' }; $line.Line
    if ($line.Line -notmatch 'fail_items=0' -or $line.Line -notmatch 'mismatches=0') { throw "RX TB failed: $($line.Line)" }
} finally { Pop-Location }
