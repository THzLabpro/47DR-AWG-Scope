# 自动寻找 AMD/Xilinx 安装目录（2025.2 版式：<根>\Vivado\bin\vivado.bat、<根>\Vitis\bin\vitis.bat、<根>\gnu\...）。
# 用法：在其他脚本里 . "$PSScriptRoot\...\scripts\xilinx_tools.ps1"，然后调用 Get-XilinxRoot / Get-VivadoBin / Get-VitisRoot。
# 查找顺序：
#   1. 环境变量 AWG_XILINX_ROOT（例如 D:\AMDDesignTools\2025.2）
#   2. XILINX_VIVADO 的上一层
#   3. PATH 里的 vivado.bat
#   4. 各固定磁盘的 AMDDesignTools\<版本>、Xilinx\<版本>、AMD\<版本>
# 优先选 2025.2（本工程用它建立）；没有就选最新版本并给出警告。

function Get-XilinxRoot {
    param([string]$Version = '2025.2')
    $cands = New-Object System.Collections.Generic.List[string]
    if ($env:AWG_XILINX_ROOT) { $cands.Add($env:AWG_XILINX_ROOT) }
    if ($env:XILINX_VIVADO) { $cands.Add((Split-Path $env:XILINX_VIVADO -Parent)) }
    $onPath = Get-Command vivado.bat -ErrorAction SilentlyContinue
    if ($onPath) { $cands.Add((Split-Path (Split-Path (Split-Path $onPath.Source -Parent) -Parent) -Parent)) }
    foreach ($drive in [IO.DriveInfo]::GetDrives()) {
        if ($drive.DriveType -ne 'Fixed' -or -not $drive.IsReady) { continue }
        foreach ($base in 'AMDDesignTools', 'Xilinx', 'AMD') {
            $dir = Join-Path $drive.RootDirectory.FullName $base
            if (Test-Path -LiteralPath $dir) {
                Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue |
                    Sort-Object Name -Descending | ForEach-Object { $cands.Add($_.FullName) }
            }
        }
    }
    $ok = @($cands | Where-Object { $_ -and [IO.File]::Exists([IO.Path]::Combine($_, 'Vivado', 'bin', 'vivado.bat')) } |
            Select-Object -Unique)
    if ($env:AWG_XILINX_ROOT -and $ok -notcontains $env:AWG_XILINX_ROOT) {
        Write-Warning "AWG_XILINX_ROOT=$($env:AWG_XILINX_ROOT) 下没有 Vivado\bin\vivado.bat，改为自动查找。"
    }
    $pick = $ok | Where-Object { (Split-Path $_ -Leaf) -eq $Version } | Select-Object -First 1
    if (-not $pick) { $pick = $ok | Select-Object -First 1 }
    if (-not $pick) {
        throw "找不到 Vivado 安装（需要 <根>\Vivado\bin\vivado.bat）。请设置环境变量 AWG_XILINX_ROOT，例如 D:\AMDDesignTools\2025.2"
    }
    if ((Split-Path $pick -Leaf) -ne $Version) {
        Write-Warning "使用 $pick；本工程用 $Version 建立，其他版本打开时 Vivado 可能要求升级 IP。"
    }
    # Vivado/Vitis 2025.2 on this kind of PC need these (otherwise 0xC0000135 / loader failures).
    $env:PROCESSOR_ARCHITECTURE = 'AMD64'
    $env:NoDefaultCurrentDirectoryInExePath = $null
    return $pick
}

function Get-VivadoBin { Join-Path (Get-XilinxRoot @args) 'Vivado\bin' }
function Get-VitisRoot { Join-Path (Get-XilinxRoot @args) 'Vitis' }
