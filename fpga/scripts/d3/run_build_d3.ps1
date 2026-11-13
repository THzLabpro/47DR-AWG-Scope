$ErrorActionPreference = 'Stop'
$env:PROCESSOR_ARCHITECTURE = 'AMD64'
$env:NoDefaultCurrentDirectoryInExePath = $null
$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. "$PSScriptRoot\..\xilinx_tools.ps1"; $vivado = Join-Path (Get-VivadoBin) 'vivado.bat'
$report = Join-Path $root 'reports\D3C_IMPL'
$build = Join-Path $root 'build\D3C_IMPL'
New-Item -ItemType Directory -Force -Path $report, $build, (Join-Path $build 'vivado') | Out-Null
$count = @(Get-Process vivado -ErrorAction SilentlyContinue).Count
while ($count -ge 3) {
    Start-Sleep -Seconds 60
    $count = @(Get-Process vivado -ErrorAction SilentlyContinue).Count
}
$log = Join-Path $report 'build_d3.log'
Push-Location $build
try {
    & $vivado -mode batch -nojournal -nolog -source (Join-Path $root 'scripts\d3\build_d3.tcl') 2>&1 | Tee-Object -FilePath $log
    $code = $LASTEXITCODE
    "EXIT_CODE build_d3 $code" | Tee-Object -FilePath $log -Append
    if ($code -eq -1073741515 -or $code -eq 1073741515) { throw 'Vivado returned 0xC0000135 (1073741515); stopping without retry.' }
    if ($code -ne 0) { throw "build_d3 failed with exit code $code" }
    if (-not (Select-String -Path $log -Pattern 'D3C_IMPL_PASS')) { throw 'D3C_IMPL_PASS marker missing' }
    $artifacts = Join-Path $report 'artifacts.txt'
    foreach ($name in 'awg_eth_v2.bit', 'awg_eth_v2.xsa') {
        $f = Join-Path $build $name
        $sha = (Get-FileHash -Algorithm SHA256 $f).Hash
        "sha256 $name $sha" | Tee-Object -FilePath $artifacts -Append
    }
} finally {
    Pop-Location
}
