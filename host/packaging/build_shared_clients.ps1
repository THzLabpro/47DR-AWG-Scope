param(
    [Parameter(Mandatory=$true)][ValidateSet('47DR','RFUDP')][string]$Project,
    [string]$RfRoot,
    [Parameter(Mandatory=$true)][string]$OutputDirectory
)
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$work=Join-Path $root ('过程文件\板卡共用\package_' + $Project)
New-Item -ItemType Directory -Force -Path $work | Out-Null
$entry=Join-Path $work 'shared_entry.py'
$tools=Join-Path $root 'host\tools'
if($Project -eq '47DR') {
    $module='awg_gui.__main__'
    $window='awg_gui.shared_window import SharedMainWindow'
    $windowName='SharedMainWindow'
    $name='47DR_Shared'
    $extra=@('--collect-data','pyqtgraph','--hidden-import','awg_gui.shared_window')
} else {
    $RfRoot=(Resolve-Path -LiteralPath $RfRoot).Path
    $module='host.analyzer.__main__'
    $window='host.analyzer.remote_window import RemoteRFUDPAnalyzer'
    $windowName='RemoteRFUDPAnalyzer'
    $name='RFUDP_Shared'
    $extra=@('--paths',$RfRoot,'--hidden-import','host.analyzer.remote_window',
        '--add-data',((Join-Path $RfRoot 'host\analyzer\icons')+';host/analyzer/icons'))
}
$target=Join-Path $OutputDirectory $name
if(Test-Path -LiteralPath $target) { throw "Output already exists: $target" }
$source="import sys`nfrom $module import main`nif __name__ == '__main__':`n    if '--shared-smoke' in sys.argv:`n        from board_share.smoke import run`n        from $window`n        sys.exit(run($windowName, sys.argv[sys.argv.index('--shared-smoke')+1]))`n    if '--shared' not in sys.argv and '--selftest' not in sys.argv: sys.argv.append('--shared')`n    sys.exit(main())`n"
[IO.File]::WriteAllText($entry,$source,[Text.UTF8Encoding]::new($false))
& py -3 -X utf8 -m PyInstaller --noconfirm --windowed --name $name --distpath $OutputDirectory --workpath (Join-Path $work 'build') --specpath $work --paths $tools --hidden-import board_share.widget --exclude-module PySide6.QtWebEngineCore --exclude-module PySide6.QtWebEngineWidgets @extra $entry
if($LASTEXITCODE -ne 0) { throw 'Client build failed' }
# Qt uses Windows' system ICU exports. A PATH-installed ICU with suffixed exports
# can be collected by PyInstaller under the same filename and break Qt startup.
$icu=Join-Path $target '_internal\icuuc.dll'
if(Test-Path -LiteralPath $icu) {
    $check="import pefile,sys; p=pefile.PE(sys.argv[1]); sys.exit(0 if b'ucnv_open' in {s.name for s in p.DIRECTORY_ENTRY_EXPORT.symbols} else 2)"
    & py -3 -c $check $icu
    if($LASTEXITCODE -eq 2) {
        $resolved=(Resolve-Path -LiteralPath $icu).Path
        $outRoot=[IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\')+'\'
        if(-not $resolved.StartsWith($outRoot,[StringComparison]::OrdinalIgnoreCase)) { throw 'ICU path outside output' }
        $saved=Join-Path $work ('excluded_icuuc_'+(Get-Date -Format yyyyMMdd_HHmmss)+'.dll')
        Move-Item -LiteralPath $resolved -Destination $saved
    } elseif($LASTEXITCODE -ne 0) { throw 'ICU dependency check failed' }
}
Write-Output "CLIENT_BUILD_OK $target"
