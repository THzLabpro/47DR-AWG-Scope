param(
    [Parameter(Mandatory=$true)][string]$RfRoot,
    [Parameter(Mandatory=$true)][string]$OutputDirectory
)
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$RfRoot=(Resolve-Path -LiteralPath $RfRoot).Path
$work=Join-Path $root '过程文件\板卡共用\package_service'
New-Item -ItemType Directory -Force -Path $work | Out-Null
$entry=Join-Path $work 'service_entry.py'
if(Test-Path -LiteralPath (Join-Path $OutputDirectory 'FPGA_Shared_Service')) { throw 'Output already exists' }
$source=@'
import json
import sys
if __name__ == '__main__':
    if '--offline-check' in sys.argv:
        import awg_eth.device
        import host.rfudp_traffic
        import host.traffic_telemetry
        import model.telemetry_udp
        from pathlib import Path
        import board_share.adapters
        script = Path(board_share.adapters.__file__).with_name('rfudp_control.tcl')
        assert script.is_file()
        print(json.dumps({'passed': True, 'hardware_accessed': False}))
    elif len(sys.argv) > 1 and sys.argv[1] == 'configure':
        sys.argv.pop(1)
        from board_share.configure_lab import main
        main()
    else:
        from board_share.lab_service import main
        main()
'@
[IO.File]::WriteAllText($entry,$source,[Text.UTF8Encoding]::new($false))
$tools=Join-Path $root 'host\tools'
& py -3 -X utf8 -m PyInstaller --noconfirm --console --name FPGA_Shared_Service --distpath $OutputDirectory --workpath (Join-Path $work 'build') --specpath $work --paths $tools --paths $RfRoot --add-data ((Join-Path $tools 'board_share\rfudp_control.tcl')+';board_share') --exclude-module PySide6.QtWebEngineCore --exclude-module PySide6.QtWebEngineWidgets $entry
if($LASTEXITCODE -ne 0) { throw 'Service build failed' }
Write-Output 'SERVICE_BUILD_OK'
