param([string]$VivadoBin = $(. "$PSScriptRoot\..\..\scripts\xilinx_tools.ps1"; Get-VivadoBin))
$ErrorActionPreference = 'Stop'
$env:PROCESSOR_ARCHITECTURE = 'AMD64'
$env:NoDefaultCurrentDirectoryInExePath = $null
$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$build = Join-Path $root 'build\D3C_IMPL\control_tb'
$report = Join-Path $root 'reports\D3C_IMPL\control_tb'
New-Item -ItemType Directory -Force -Path $build, $report | Out-Null
Push-Location $build
try {
    & (Join-Path $VivadoBin 'xvlog.bat') -sv -nolog -log (Join-Path $report 'control_xvlog.log') `
        (Join-Path $root 'rtl\ctrl\awg_control_v2.sv') `
        (Join-Path $root 'sim\d3\tb_awg_control_v2.sv') 2>&1 | Tee-Object -FilePath (Join-Path $report 'control_xvlog_console.log')
    if ($LASTEXITCODE -eq -1073741515 -or $LASTEXITCODE -eq 1073741515) { throw 'xvlog returned 0xC0000135 (1073741515); stopping without retry.' }
    if ($LASTEXITCODE -ne 0) { throw "xvlog failed: $LASTEXITCODE" }
    & (Join-Path $VivadoBin 'xelab.bat') work.tb_awg_control_v2 -s tb_awg_control_v2_sim -nolog -log (Join-Path $report 'control_xelab.log') 2>&1 | Tee-Object -FilePath (Join-Path $report 'control_xelab_console.log')
    if ($LASTEXITCODE -eq -1073741515 -or $LASTEXITCODE -eq 1073741515) { throw 'xelab returned 0xC0000135 (1073741515); stopping without retry.' }
    if ($LASTEXITCODE -ne 0) { throw "xelab failed: $LASTEXITCODE" }
    & (Join-Path $VivadoBin 'xsim.bat') tb_awg_control_v2_sim -runall -nolog 2>&1 | Tee-Object -FilePath (Join-Path $report 'control_xsim.log')
    if ($LASTEXITCODE -ne 0) { throw "xsim failed: $LASTEXITCODE" }
    $result = Select-String -Path (Join-Path $report 'control_xsim.log') -Pattern '^RESULT name=tb_awg_control_v2 '
    if (-not $result) { throw 'control TB missing RESULT line' }
    $result.Line
    if ($result.Line -notmatch 'FAIL=0') { throw "control TB failed: $($result.Line)" }
} finally { Pop-Location }
