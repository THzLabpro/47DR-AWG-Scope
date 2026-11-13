$ErrorActionPreference = 'Stop'
$env:PROCESSOR_ARCHITECTURE = 'AMD64'
$env:NoDefaultCurrentDirectoryInExePath = $null

$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. "$PSScriptRoot\..\..\scripts\xilinx_tools.ps1"; $vivado = Get-VivadoBin
$build = Join-Path $root 'build/D1R2_TX'
$report = Join-Path $root 'reports/D1R2_TX'
$xvlogLog = Join-Path $report 'xvlog.log'
$xelabLog = Join-Path $report 'xelab.log'
$xsimLog = Join-Path $report 'xsim.log'

New-Item -ItemType Directory -Force -Path $build, $report | Out-Null
$simDir = Join-Path $build 'xsim.dir'
if (Test-Path $simDir) {
    $resolvedBuild = (Resolve-Path $build).Path
    $resolvedSimDir = [System.IO.Path]::GetFullPath($simDir)
    if (-not $resolvedSimDir.StartsWith($resolvedBuild, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Simulation output path escaped the task build directory: $resolvedSimDir"
    }
    Remove-Item -LiteralPath $resolvedSimDir -Recurse -Force
}

Push-Location $build
try {
    & (Join-Path $vivado 'xvlog.bat') -sv -nolog -log $xvlogLog `
        (Join-Path $root 'rtl/tx/awg_tx_uram_block.sv') `
        (Join-Path $root 'rtl/tx/awg_tx.sv') `
        (Join-Path $root 'sim/tx/tb_awg_tx.sv')
    if ($LASTEXITCODE -ne 0) { throw "xvlog failed with exit code $LASTEXITCODE" }

    & (Join-Path $vivado 'xelab.bat') -L xpm tb_awg_tx -s tb_awg_tx_sim `
        --debug off -nolog -log $xelabLog
    if ($LASTEXITCODE -ne 0) { throw "xelab failed with exit code $LASTEXITCODE" }

    & (Join-Path $vivado 'xsim.bat') tb_awg_tx_sim -runall -nolog 2>&1 |
        Tee-Object -FilePath $xsimLog
    $xsimExit = $LASTEXITCODE
    if ($xsimExit -ne 0) { throw "xsim failed with exit code $xsimExit" }
    $resultLine = Select-String -Path $xsimLog -Pattern '^RESULT name=tb_awg_tx '
    if (-not $resultLine) { throw 'xsim ended without the required RESULT summary' }
    if ($resultLine.Line -notmatch 'PASS=26 FAIL=0 mismatches=0 x_count=0') {
        throw "T1-T6 acceptance failed: $($resultLine.Line)"
    }
}
finally {
    Pop-Location
}
