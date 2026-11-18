"""Offline failure-path checks: never access physical adapters or JTAG."""
import threading
from unittest.mock import Mock, patch
import pytest
from .adapters import AwgAdapter, HardwareAdapter
from awg_eth.client import AwgEthError


def setup_adapter():
    a = AwgAdapter({})
    package = {'link_recovery': {'verify': ['verify-only'], 'restart': ['restart-only']}}
    return a, package, threading.Event()


def test_healthy_switch_never_restarts_adapter():
    a, p, cancel = setup_adapter()
    with patch.object(HardwareAdapter, 'program'), patch.object(a, '_wait_ready'), patch.object(a, '_recover_link') as recovery:
        a.program(p, cancel)
    recovery.assert_not_called()


@pytest.mark.parametrize('error', [AwgEthError('FPGA timeout after 5 retries'), TimeoutError(), RuntimeError('V2.1 bulk port unavailable; check UDP 9101 and MTU 9000')])
def test_recovery_is_ordered_and_rechecks_both_ports(error):
    a, p, cancel = setup_adapter()
    with patch.object(HardwareAdapter, 'program'), patch.object(a, '_wait_ready', side_effect=[error, None]) as ready, \
            patch('board_share.adapters.command', side_effect=['REG values\nAWG_F3_JTAG_READY\n', 'OPTICAL_ADAPTER_RESTARTED\n']) as command:
        a.program(p, cancel)
    assert [c.args[0] for c in command.call_args_list] == [['verify-only'], ['restart-only']]
    assert [c.args[1] for c in ready.call_args_list] == [60, 30]
    assert '验证通过' in a.events(0)['events'][-1]['value']


@pytest.mark.parametrize('error', [ValueError('V2.1 firmware mismatch'), RuntimeError('PS 初始化尚未完成'), OSError('unrelated error')])
def test_wrong_firmware_or_unready_ps_never_restarts(error):
    a, p, cancel = setup_adapter()
    with patch.object(HardwareAdapter, 'program'), patch.object(a, '_wait_ready', side_effect=error), patch.object(a, '_recover_link') as recovery:
        with pytest.raises(type(error)):
            a.program(p, cancel)
    recovery.assert_not_called()


def test_jtag_mismatch_does_not_restart():
    a, p, cancel = setup_adapter()
    with patch('board_share.adapters.command', return_value='puts "AWG_F3_JTAG_READY"') as command:
        with pytest.raises(RuntimeError, match='verify'):
            a._recover_link(p, cancel)
    assert command.call_count == 1


def test_cancellation_between_probe_and_restart():
    a, p, cancel = setup_adapter()
    def probe(*args, **kwargs):
        cancel.set()
        return 'AWG_F3_JTAG_READY'
    with patch('board_share.adapters.command', side_effect=probe) as command:
        with pytest.raises(RuntimeError, match='取消'):
            a._recover_link(p, cancel)
    assert command.call_count == 1


def test_still_dead_restarts_only_once():
    a, p, cancel = setup_adapter()
    with patch.object(HardwareAdapter, 'program'), patch.object(a, '_wait_ready', side_effect=TimeoutError()), patch.object(a, '_recover_link') as recovery:
        with pytest.raises(TimeoutError):
            a.program(p, cancel)
    recovery.assert_called_once()


def test_legacy_config_does_not_enable_recovery():
    a, _, cancel = setup_adapter()
    with patch.object(HardwareAdapter, 'program'), patch.object(a, '_wait_ready', side_effect=TimeoutError()), patch.object(a, '_recover_link') as recovery:
        with pytest.raises(TimeoutError):
            a.program({}, cancel)
    recovery.assert_not_called()


def test_faulted_board_is_not_reported_ready():
    a, _, cancel = setup_adapter()
    a.awg = Mock()
    a.awg.status.return_value = {'ps_ready': 1, 'fault': 1}
    with pytest.raises(ValueError, match='故障'):
        a._wait_ready(cancel, 60)


def test_recovery_helpers_are_sealed(tmp_path):
    from .configure_lab import add_awg_link_recovery
    from .coordinator import Catalog, Rejected
    for name in ['vivado.bat', 'awg_identity.tcl', 'recover_optical.ps1']:
        (tmp_path / name).write_text('test')
    config = {'adapters': {'47DR': {'fpga_ip': '192.168.42.2'}},
              'packages': {'47DR-F3': {'project': '47DR', 'files': {}}}}
    add_awg_link_recovery(config, tmp_path/'vivado.bat', ['41155374-19d2-4e24-8e5d-c027bedc3d9e'], '192.168.42.20', '15051A', tmp_path)
    catalog = Catalog(config['packages'])
    catalog.resolve('47DR-F3')
    (tmp_path/'recover_optical.ps1').write_text('changed')
    with pytest.raises(Rejected, match='变化'):
        catalog.resolve('47DR-F3')

@pytest.mark.parametrize('bad_address,bad_value', [(None, None), ('90200054', 'DEADBEEF'), ('90200020', '00040000'), ('90200004', '00000000'), ('90200004', '00000005'), ('9020001c', '00000001')])
def test_readonly_jtag_probe_contract(bad_address, bad_value):
    import tkinter
    from pathlib import Path
    t = tkinter.Tcl()
    t.eval('''
        set argv {15051A}
        proc open_hw_manager {} {}
        proc connect_hw_server {args} {}
        proc get_hw_targets {args} {return {localhost/xilinx/15051A}}
        proc open_hw_target {args} {}
        proc get_hw_devices {args} {return {xczu47dr_0}}
        proc current_hw_device {args} {}
        proc refresh_hw_device {args} {}
        proc get_hw_axis {args} {return {axi}}
        proc create_hw_axi_txn {args} {return [lindex $args 0]}
        proc run_hw_axi {args} {}
        proc delete_hw_axi_txn {args} {}
        proc close_hw_target {} {}
        proc disconnect_hw_server {} {}
        proc close_hw_manager {} {}
        proc exit {} {}
        rename puts original_puts
        set messages {}
        proc puts {message} {global messages; lappend messages $message}
        array set registers {90200000 41574732 90200020 00050000 90200054 d4b02026 90200014 00958940 90200018 004c4b40 9020001c 00000000 90200004 00000004}
        proc get_property {name tx} {global registers; return $registers([string range $tx 6 end])}
    ''')
    if bad_address:
        t.setvar('registers('+bad_address+')', bad_value)
    script = Path(__file__).with_name('awg_identity.tcl').read_text()
    if bad_address:
        with pytest.raises(tkinter.TclError):
            t.eval(script)
        assert 'AWG_F3_JTAG_READY' not in str(t.getvar('messages'))
    else:
        t.eval(script)
        assert 'AWG_F3_JTAG_READY' in str(t.getvar('messages'))


@pytest.mark.parametrize('case', ['good', 'wrong_guid', 'ambiguous', 'down', 'wrong_ip'])
def test_powershell_selects_only_allowlisted_active_route(tmp_path, case):
    import os
    import subprocess
    from pathlib import Path
    if os.name != 'nt':
        pytest.skip('Windows adapter helper')
    script = str(Path(__file__).with_name('recover_optical.ps1').resolve()).replace("'", "''")
    harness = r'''
$ErrorActionPreference='Stop'
$global:restarted=0
$script:case='CASE'
$global:mockNic=[pscustomobject]@{ifIndex=9; InterfaceGuid='{41155374-19D2-4E24-8E5D-C027BEDC3D9E}';Name='optical-test';Status='Up'}
if($case -eq 'wrong_guid'){$global:mockNic.InterfaceGuid='{E472D329-717A-4263-A34F-3EA7AC5E4EE6}'}
if($case -eq 'down'){$global:mockNic.Status='Disconnected'}
function Find-NetRoute {param($RemoteIPAddress,$LocalIPAddress) [pscustomobject]@{InterfaceIndex=9}; if($case -eq 'ambiguous'){[pscustomobject]@{InterfaceIndex=18}}}
function Get-NetAdapter {param([switch]$Physical) $global:mockNic}
function Get-NetIPAddress {param($InterfaceIndex,$AddressFamily) if($case -ne 'wrong_ip'){[pscustomobject]@{IPAddress='192.168.42.20'}}}
function Restart-NetAdapter {param($InputObject,[switch]$Confirm) if($InputObject.Name -ne 'optical-test'){throw 'Wrong NIC'}; $global:restarted++}
function Start-Sleep {param($Milliseconds)}
$failed=$false
try { & 'SCRIPT' -Mode Restart -HostIP 192.168.42.20 -BoardIP 192.168.42.2 -AllowedInterfaceGuids '41155374-19d2-4e24-8e5d-c027bedc3d9e' } catch { $failed=$true; Write-Output $_.Exception.Message }
if($case -eq 'good'){if($failed -or $restarted -ne 1){throw 'Expected one restart'}}
else {if(-not $failed -or $restarted -ne 0){throw 'Invalid route must not restart'}}
Write-Output 'MOCK_ADAPTER_PASS'
'''.replace('CASE', case).replace('SCRIPT', script)
    path = tmp_path/'mock.ps1'
    path.write_text(harness, encoding='utf-8-sig')
    r = subprocess.run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',str(path)],capture_output=True)
    assert r.returncode == 0, r.stdout+r.stderr
    assert b'MOCK_ADAPTER_PASS' in r.stdout
