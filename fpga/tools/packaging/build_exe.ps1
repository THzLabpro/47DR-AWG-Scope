<#
.SYNOPSIS
  把 47DR AWG/示波器上位机打包成免安装文件夹 <OutDir>\AWG47DR_V1\AWG47DR_V1.exe，并把固件包放进 firmware\。
.DESCRIPTION
  需要 Python 3.12，以及 numpy、scipy、PySide6、pyqtgraph、pyinstaller==6.22.3。
  -PythonExe 指定已经装好这些库的解释器；不指定时会在 <脚本目录>\venv 新建 venv（--system-site-packages），并用 pip 安装 pyinstaller。
  固件包（bit/elf/psu_init.tcl/init_protocol.txt）默认来自 <工程>\build\F1\package，program.tcl 来自 <工程>\scripts。
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\packaging\build_exe.ps1 -OutDir D:\out
#>
param(
    [string]$ProjectDir = (Join-Path $PSScriptRoot '..\..'),
    [string]$OutDir = (Join-Path $PSScriptRoot 'dist'),
    [string]$PythonExe = '',
    [string]$Package = '',
    [string]$Xsa = ''
)
$ErrorActionPreference = 'Stop'
$ProjectDir = (Resolve-Path -LiteralPath $ProjectDir).Path
$tools = Join-Path $ProjectDir 'tools'
if (-not $Package) { $Package = Join-Path $ProjectDir 'build\F1\package' }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path
$work = Join-Path $PSScriptRoot 'work'
if (-not $PythonExe) {
    $venv = Join-Path $PSScriptRoot 'venv'
    if (-not (Test-Path (Join-Path $venv 'Scripts\python.exe'))) { & py -3.12 -m venv --system-site-packages $venv }
    $PythonExe = Join-Path $venv 'Scripts\python.exe'
    & $PythonExe -m pip install --disable-pip-version-check 'pyinstaller==6.22.3'
}
$name = 'AWG47DR_V1'
$pyiArgs = @('-m', 'PyInstaller', '--noconfirm', '--clean', '--windowed', '--name', $name,
    '--distpath', $OutDir, '--workpath', $work, '--specpath', $work,
    '--paths', $tools,
    '--hidden-import', 'awg_gui.main_window', '--hidden-import', 'awg_eth.fpga_emu',
    '--hidden-import', 'scipy.io', '--collect-submodules', 'pyqtgraph',
    '--exclude-module', 'PySide6.QtWebEngineCore', '--exclude-module', 'PySide6.QtWebEngineWidgets',
    '--exclude-module', 'PySide6.QtWebEngineQuick', '--exclude-module', 'PySide6.QtPdf',
    '--exclude-module', 'PySide6.QtQuick', '--exclude-module', 'PySide6.QtQml', '--exclude-module', 'PySide6.Qt3DCore',
    '--exclude-module', 'PySide6.QtMultimedia', '--exclude-module', 'matplotlib', '--exclude-module', 'tkinter',
    '--exclude-module', 'pytest',
    (Join-Path $PSScriptRoot 'awg47dr_entry.py'))
& $PythonExe @pyiArgs
if ($LASTEXITCODE -ne 0) { throw "PyInstaller failed ($LASTEXITCODE)" }

# firmware\ next to the exe: the GUI's 「设备 → 下载 bit 并初始化」 uses it directly on any PC.
$fw = Join-Path $OutDir "$name\firmware"
New-Item -ItemType Directory -Force $fw | Out-Null
foreach ($f in 'rf_awg_scope_v1.bit', 'rf_awg_init.elf', 'psu_init.tcl', 'init_protocol.txt') {
    Copy-Item -LiteralPath (Join-Path $Package $f) -Destination $fw -Force
}
Copy-Item -LiteralPath (Join-Path $ProjectDir 'scripts\program.tcl') -Destination $fw -Force
$trace = Join-Path $ProjectDir 'scripts\read_init_trace.tcl'
if (Test-Path -LiteralPath $trace) { Copy-Item -LiteralPath $trace -Destination $fw -Force }
if ($Xsa -and (Test-Path -LiteralPath $Xsa)) { Copy-Item -LiteralPath $Xsa -Destination $fw -Force }
Get-ChildItem -LiteralPath $fw -File | ForEach-Object {
    '{0}  {1}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash, $_.Name
} | Set-Content -Encoding utf8 (Join-Path $fw 'SHA256SUMS.txt')
Write-Output "EXE_BUILD_OK $OutDir\$name\$name.exe"
