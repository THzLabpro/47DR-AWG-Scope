# F1 firmware build: SDT BSP from the v2 XSA (Vitis 2025.2), then compile/link software/src.
# Usage: .\software\build\build_fw.ps1 [-Xsa <path.xsa>] [-ReuseBsp]
# No hardware access. Outputs go to build/F1/; the published ELF is build/F1/rf_awg_init.elf.
param([string]$Xsa = '', [switch]$ReuseBsp = $false)
$ErrorActionPreference = 'Stop'
$env:PROCESSOR_ARCHITECTURE = 'AMD64'
$env:NoDefaultCurrentDirectoryInExePath = $null
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. "$PSScriptRoot\..\..\scripts\xilinx_tools.ps1"; $toolRoot = Get-XilinxRoot
$gnu = Join-Path $toolRoot 'gnu\aarch64\nt\aarch64-none\bin'
$out = Join-Path $root 'build\F1'
$bsp = Join-Path $out 'bsp'
if ($Xsa -eq '') { $Xsa = Join-Path $root 'build\D3C_IMPL\awg_eth_v2.xsa' }
$Xsa = (Resolve-Path -LiteralPath $Xsa).Path
New-Item -ItemType Directory -Force -Path $out | Out-Null

# 1. SDT BSP (standalone, psu_cortexa53_0, libmetal pulled in by the RFDC driver).
if (-not ($ReuseBsp -and (Test-Path (Join-Path $bsp 'ws\bsp.ok')))) {
    if (Test-Path $bsp) { Remove-Item -Recurse -Force $bsp }
    New-Item -ItemType Directory -Force -Path (Join-Path $bsp 'ws'), (Join-Path $bsp 'tmp') | Out-Null
    Copy-Item -LiteralPath $Xsa -Destination (Join-Path $bsp 'hardware.xsa')
    $env:TEMP = Join-Path $bsp 'tmp'; $env:TMP = $env:TEMP; $env:PYTHONDONTWRITEBYTECODE = '1'
    $req = Join-Path $bsp 'request.json'
    @{ workspace = (Join-Path $bsp 'ws'); xsa = (Join-Path $bsp 'hardware.xsa') } | ConvertTo-Json | Set-Content -LiteralPath $req -Encoding UTF8
    $env:AWG_FW_REQUEST = $req
    Push-Location (Join-Path $bsp 'ws')
    try {
        $ErrorActionPreference = 'Continue'
        & (Join-Path $toolRoot 'Vitis\bin\vitis.bat') -s (Join-Path $PSScriptRoot 'build_vitis_bsp.py') 2>&1 | Out-File -Encoding utf8 (Join-Path $bsp 'vitis.log')
    } finally { $ErrorActionPreference = 'Stop'; Pop-Location }
    if (-not (Test-Path (Join-Path $bsp 'ws\bsp.ok'))) { throw "SDT BSP build failed; see $bsp\vitis.log" }
}
$xsaHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $bsp 'hardware.xsa')).Hash
if ($xsaHash -ne (Get-FileHash -Algorithm SHA256 -LiteralPath $Xsa).Hash) { throw 'BSP was built from a different XSA; rerun without -ReuseBsp' }
$export = Join-Path $bsp 'ws\awg\export\awg\sw\a53'
$inc = Join-Path $export 'include'
$lib = Join-Path $export 'lib'
foreach ($p in $inc, $lib) { if (-not (Test-Path $p)) { throw "Missing BSP export dir $p" } }

# 2. Compile and link (flags as in scripts/build_software.ps1, plus -DSDT).
$src = Join-Path $root 'software\src'
$obj = Join-Path $out 'obj'
if (Test-Path $obj) { Remove-Item -Recurse -Force $obj }
New-Item -ItemType Directory -Force -Path $obj | Out-Null
$cc = Join-Path $gnu 'aarch64-none-elf-gcc.exe'
$spec = Join-Path $export 'Xilinx.spec'
# XLNX_PLATFORM selects libmetal's xlnx sys.h, matching how the BSP built libmetal.
$cflags = @('-Wall', '-O0', '-g3', '-DSDT', '-DXLNX_PLATFORM', '-D__BAREMETAL__', '-mcpu=cortex-a53', "-specs=$spec",
            "-I$inc", "-I$(Join-Path $src 'devices')", "-I$(Join-Path $src 'rfsoc')", "-I$src")
$log = Join-Path $out 'compile.log'
'' | Set-Content $log
$objs = @()
foreach ($f in Get-ChildItem $src -Recurse -Filter '*.c') {
    $name = $f.FullName.Substring($src.Length + 1).Replace('\', '_') + '.o'
    $o = Join-Path $obj $name
    $ErrorActionPreference = 'Continue'
    & $cc @cflags -c $f.FullName -o $o 2>&1 | Tee-Object -FilePath $log -Append
    $rc = $LASTEXITCODE; $ErrorActionPreference = 'Stop'
    if ($rc -ne 0) { throw "Compile failed: $($f.Name)" }
    $objs += $o
}
$elf = Join-Path $out 'rf_awg_init.elf'
$libs = @('xil', 'xilstandalone', 'xiltimer', 'metal') | Where-Object { Test-Path (Join-Path $lib "lib$_.a") }
$lflags = @('-mcpu=cortex-a53', "-specs=$spec", "-Wl,-T,$(Join-Path $src 'lscript.ld')", "-L$lib", "-Wl,-Map=$(Join-Path $out 'rf_awg_init.map')", '-o', $elf)
$ErrorActionPreference = 'Continue'
& $cc @lflags @objs '-Wl,--start-group' ($libs | ForEach-Object { "-l$_" }) '-lm' '-lgcc' '-lc' '-Wl,--end-group' 2>&1 | Tee-Object -FilePath $log -Append
$rc = $LASTEXITCODE; $ErrorActionPreference = 'Stop'
if ($rc -ne 0) { throw 'ELF link failed' }

# 3. Summary.
& (Join-Path $gnu 'aarch64-none-elf-size.exe') $elf | Tee-Object -FilePath (Join-Path $out 'size.txt')
& (Join-Path $gnu 'aarch64-none-elf-readelf.exe') -lW $elf | Set-Content (Join-Path $out 'segments.txt')
& (Join-Path $gnu 'aarch64-none-elf-nm.exe') -n -S $elf | Set-Content (Join-Path $out 'symbols.txt')
$elfHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $elf).Hash
"elf=$elf sha256=$elfHash`nxsa=$Xsa sha256=$xsaHash`nlibs=$($libs -join ',')" | Tee-Object -FilePath (Join-Path $out 'artifacts.txt')

# 4. Board package in the layout scripts/program.tcl -package expects (files only; nothing is downloaded).
$pkg = Join-Path $out 'package'
if (Test-Path $pkg) { Remove-Item -Recurse -Force $pkg }
New-Item -ItemType Directory -Force -Path $pkg | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($Xsa)
try {
    foreach ($pair in @(@('psu_init.tcl', 'psu_init.tcl'), @('awg_eth_v2.bit', 'rf_awg_scope_v1.bit'))) {
        $entry = $zip.Entries | Where-Object { $_.FullName -eq $pair[0] } | Select-Object -First 1
        if ($null -eq $entry) { throw "XSA has no $($pair[0])" }
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $pkg $pair[1]))
    }
} finally { $zip.Dispose() }
Copy-Item -LiteralPath $elf -Destination (Join-Path $pkg 'rf_awg_init.elf')
$names = @('awg_clock_ready', 'awg_pl_program_ack', 'awg_init_log', 'awg_init_log_length', 'init_stage_debug')
$symbols = @{}
foreach ($line in (& (Join-Path $gnu 'aarch64-none-elf-nm.exe') $elf)) {
    if ($line -match '^([0-9a-fA-F]+)\s+\w\s+(\w+)$' -and $names -contains $Matches[2]) { $symbols[$Matches[2]] = '0x' + $Matches[1] }
}
$protocol = @('protocol_version 1')
foreach ($n in $names) {
    if (-not $symbols.ContainsKey($n)) { throw "ELF is missing initialization protocol symbol: $n" }
    $protocol += "$n $($symbols[$n])"
}
$protocol | Set-Content -LiteralPath (Join-Path $pkg 'init_protocol.txt') -Encoding ascii
Get-ChildItem $pkg -File | ForEach-Object { "package $($_.Name) size=$($_.Length) sha256=$((Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash)" } |
    Tee-Object -FilePath (Join-Path $out 'artifacts.txt') -Append
Write-Output "F1_FIRMWARE_BUILD_PASS $elf"
