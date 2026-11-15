# Build awg_bulk.dll with the mingw-w64 gcc that ships with Vivado (no runtime DLL dependencies).
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\awg_eth\native\build.ps1 [-Gcc <path to gcc.exe>]
param([string]$Gcc = '')
$ErrorActionPreference = 'Stop'
if (-not $Gcc) {
    $roots = @()
    if ($env:AWG_XILINX_ROOT) { $roots += $env:AWG_XILINX_ROOT }
    $roots += @('D:\AMDDesignTools\2025.2', 'C:\AMDDesignTools\2025.2', 'C:\Xilinx\2025.2', 'D:\Xilinx\2025.2')
    foreach ($r in $roots) {
        $hit = Get-ChildItem -Path (Join-Path $r 'Vivado\tps\mingw') -Filter gcc.exe -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match 'win64' } | Select-Object -First 1
        if ($hit) { $Gcc = $hit.FullName; break }
    }
}
if (-not $Gcc -or -not (Test-Path $Gcc)) { throw 'mingw gcc.exe not found; pass -Gcc or set AWG_XILINX_ROOT' }
$env:PATH = (Split-Path $Gcc) + ';' + $env:PATH
$src = Join-Path $PSScriptRoot 'awg_bulk.c'
$dll = Join-Path $PSScriptRoot 'awg_bulk.dll'
$new = Join-Path $PSScriptRoot 'awg_bulk.new.dll'
& $Gcc -O2 -Wall -Wextra -shared -static -static-libgcc -s -o $new $src -lws2_32
if ($LASTEXITCODE -ne 0) { throw "gcc failed ($LASTEXITCODE)" }
# A running GUI keeps the old DLL loaded: Windows lets a loaded DLL be renamed, not overwritten.
Get-ChildItem $PSScriptRoot -Filter 'awg_bulk.dll.old*' | ForEach-Object { Remove-Item $_.FullName -ErrorAction SilentlyContinue }
if (Test-Path $dll) {
    try { Remove-Item $dll -ErrorAction Stop } catch { Rename-Item $dll ("awg_bulk.dll.old" + (Get-Date -Format 'yyyyMMddHHmmss')) }
}
Rename-Item $new 'awg_bulk.dll'
& $Gcc --version | Select-Object -First 1
Get-Item $dll | Select-Object Name, Length
