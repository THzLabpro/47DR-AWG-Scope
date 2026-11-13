param(
    [string]$VivadoBin = $(. "$PSScriptRoot\..\..\scripts\xilinx_tools.ps1"; Get-VivadoBin),
    [string]$TestPlusarg = ''
)

$ErrorActionPreference = 'Stop'
$env:PROCESSOR_ARCHITECTURE = 'AMD64'
$env:NoDefaultCurrentDirectoryInExePath = $null

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$buildDir = Join-Path $root 'build\D3A3_INTEGRATION\sim_rx'
$reportDir = Join-Path $root 'reports\D3A3_INTEGRATION'
New-Item -ItemType Directory -Force -Path $buildDir, $reportDir | Out-Null

$rtl = Join-Path $root 'rtl\rx\awg_rx.sv'
$tb = Join-Path $PSScriptRoot 'tb_awg_rx.sv'
$glbl = Join-Path $VivadoBin '..\data\verilog\src\glbl.v'
$snapshot = 'tb_awg_rx_sim'

function Invoke-VivadoTool {
    param(
        [string]$Name,
        [string]$Executable,
        [string[]]$Arguments,
        [string]$LogPath
    )

    "COMMAND $Name $($Arguments -join ' ')" | Tee-Object -FilePath $LogPath -Append
    $toolOutput = & $Executable @Arguments 2>&1
    $toolExitCode = $LASTEXITCODE
    $toolOutput | Tee-Object -FilePath $LogPath -Append
    "EXIT_CODE $Name $toolExitCode" | Tee-Object -FilePath $LogPath -Append
    if ($toolExitCode -eq -1073741515 -or $toolExitCode -eq 1073741515) {
        throw "$Name returned 0xC0000135 (1073741515); stopping without retry."
    }
    if ($toolExitCode -ne 0) {
        throw "$Name failed with exit code $toolExitCode."
    }
}

Push-Location $buildDir
try {
    $compileLog = Join-Path $reportDir 'xvlog.log'
    $elabLog = Join-Path $reportDir 'xelab.log'
    $simLog = Join-Path $reportDir 'xsim.log'
    Remove-Item -LiteralPath $compileLog, $elabLog, $simLog -Force -ErrorAction SilentlyContinue

    Invoke-VivadoTool -Name 'xvlog' -Executable (Join-Path $VivadoBin 'xvlog.bat') `
        -Arguments @('-sv', '-L', 'xpm', $rtl, $tb, $glbl) -LogPath $compileLog
    Invoke-VivadoTool -Name 'xelab' -Executable (Join-Path $VivadoBin 'xelab.bat') `
        -Arguments @('-L', 'xpm', 'work.tb_awg_rx', 'work.glbl', '-s', $snapshot, '-debug', 'typical') -LogPath $elabLog
    $simArgs = @($snapshot)
    if ($TestPlusarg) { $simArgs += @('--testplusarg', $TestPlusarg) }
    $simArgs += @('-runall')
    Invoke-VivadoTool -Name 'xsim' -Executable (Join-Path $VivadoBin 'xsim.bat') `
        -Arguments $simArgs -LogPath $simLog

    $resultLine = Select-String -Path $simLog -Pattern '^RESULT name=tb_awg_rx (PASS|FAIL)' | Select-Object -Last 1
    if (-not $resultLine) {
        throw 'xsim completed without a tb_awg_rx RESULT line.'
    }
    $resultLine.Line | Set-Content -Encoding utf8 (Join-Path $reportDir 'sim_result.txt')
    Write-Output $resultLine.Line
}
finally {
    Pop-Location
}
