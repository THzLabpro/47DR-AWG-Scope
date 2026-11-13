$ErrorActionPreference = 'Stop'
$env:PROCESSOR_ARCHITECTURE = 'AMD64'
$env:NoDefaultCurrentDirectoryInExePath = $null

$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. "$PSScriptRoot\..\..\scripts\xilinx_tools.ps1"; $vivado = Join-Path (Get-VivadoBin) 'vivado.bat'
$reportDir = Join-Path $root 'reports/D1R2_TX'
$build = Join-Path $root 'build/D1R2_TX'
$report = Join-Path $reportDir 'ooc_vivado.log'
New-Item -ItemType Directory -Force -Path $reportDir, $build | Out-Null

$vivadoCount = (Get-Process vivado -ErrorAction SilentlyContinue).Count
while ($vivadoCount -ge 3) {
    Start-Sleep -Seconds 60
    $vivadoCount = (Get-Process vivado -ErrorAction SilentlyContinue).Count
}

Push-Location $root
try {
    & $vivado -mode batch -source (Join-Path $build 'ooc.tcl') `
        -nolog -nojournal 2>&1 | Tee-Object -FilePath $report
    $vivadoExit = $LASTEXITCODE
    if ($vivadoExit -ne 0) { throw "Vivado OOC failed with exit code $vivadoExit" }
}
finally {
    Pop-Location
}
