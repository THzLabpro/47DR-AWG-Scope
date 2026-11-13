$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$buildDir = Join-Path $projectRoot 'build\E2'
$reportDir = Join-Path $projectRoot 'reports\E2'
. "$PSScriptRoot\..\..\scripts\xilinx_tools.ps1"; $vivado = Join-Path (Get-VivadoBin) 'vivado.bat'
$logPath = Join-Path $reportDir 'E2_ooc_synth.log'

New-Item -ItemType Directory -Force -Path $buildDir, $reportDir | Out-Null
$env:PROCESSOR_ARCHITECTURE = 'AMD64'
$env:NoDefaultCurrentDirectoryInExePath = $null
Set-Location $projectRoot

& $vivado -mode batch -source (Join-Path $PSScriptRoot 'ooc_synth.tcl') -log $logPath
$toolExitCode = $LASTEXITCODE
if ($toolExitCode -eq 1073741515) {
    throw 'Vivado returned 0xC0000135 (1073741515). Stop without retry.'
}
if ($toolExitCode -ne 0) {
    throw "Vivado OOC synthesis failed with exit code $toolExitCode. See $logPath"
}

Write-Output "E2 OOC synthesis completed; reports: $buildDir"
