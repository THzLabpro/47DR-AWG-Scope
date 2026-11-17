import threading
from pathlib import Path
from unittest.mock import patch
import pytest
from .adapters import AwgAdapter, Events, RfUdpAdapter
from .coordinator import Rejected


def test_awg_real_adapter_loopback_only():
    import numpy as np
    from awg_eth.fpga_emu import FpgaEmulator
    from awg_eth.remote import encode_arrays, decode_arrays
    with FpgaEmulator(abi=3, build_id=0xD4B02026, loopback=True).start() as emu:
        a = AwgAdapter({'fpga_ip': '127.0.0.1', 'fpga_port': emu.port, 'cleanup_validated': True})
        package = {'identity': 'offline-emulator'}
        a.package = package  # no programming process during this test
        cancel = threading.Event()
        task = {'operation': 'load_words', 'package': package,
                'parameters': {'channels': encode_arrays({0: np.arange(32, dtype='uint32')}),
                               'samples': 64, 'mask': 1, 'verify': True, 'auto_run': True}}
        result = a.execute(task, cancel)
        assert result['status']['running']
        assert a.verify()['verified_project'] == '47DR'
        capture = a.execute({'operation': 'capture_raw', 'package': package,
                             'parameters': {'mask': 1, 'samples': 96}}, cancel)
        assert capture['count'] == 96
        assert set(decode_arrays(capture['channels'])) == {0}
        assert a.cleanup() is True
        assert a.awg is None


def test_cleanup_requires_explicit_bench_gate():
    a = AwgAdapter({})
    class Fake:
        def abort_capture(self): pass
        def stop(self): pass
        def status(self): return {'running': False, 'busy': False, 'cap_busy': False, 'ps_ready': True, 'fault': 0}
        def close(self): pass
    a.awg = Fake()
    assert a.cleanup() is False


@pytest.mark.parametrize('field,value', [('running', True), ('busy', True), ('cap_busy', True), ('ps_ready', False), ('fault', 1)])
def test_awg_cleanup_rejects_unfinished_or_faulted_hardware(field, value):
    from unittest.mock import Mock
    a = AwgAdapter({'cleanup_validated': True})
    status = dict(running=False, busy=False, cap_busy=False, ps_ready=True, fault=0)
    status[field] = value
    awg = a.awg = Mock()
    awg.status.return_value = status
    assert a.cleanup() is False
    awg.close.assert_called_once()
    assert a.awg is None


def test_rf_cleanup_still_stops_output_when_reader_fails():
    a = RfUdpAdapter({'cleanup_validated': True})
    with patch.object(a, '_stop_uart', side_effect=RuntimeError('reader stuck')), \
         patch.object(a, '_stop_udp') as udp, patch.object(a, '_command') as command:
        with pytest.raises(RuntimeError, match='reader stuck'):
            a.cleanup()
        udp.assert_called_once()
        assert command.call_args.args[0] == 'stop_output'


def test_rf_commands_validate_readback_and_rate_encoding():
    a = RfUdpAdapter({'root': '.', 'commands': {
        'lms': {'argv': ['xsdb', '{value}'], 'pass': 'LMS_PASS {value}'},
        'rate': {'argv': ['xsdb', '{value}'], 'pass': 'RATE_SWITCH_PASS'},
        'dac': {'argv': ['xsdb', '{value}'], 'pass': 'DAC0_CURRENT_PASS'}}})
    with patch('board_share.adapters.command', return_value='AFTER 0x00000006\nLMS_PASS 6'):
        a._command('lms', threading.Event(), 6)
    with patch('board_share.adapters.command', return_value='AFTER 0x00000002\nLMS_PASS 6'):
        with pytest.raises(RuntimeError):
            a._command('lms', threading.Event(), 6)
    with patch('board_share.adapters.command', return_value='RATE_SWITCH_PASS') as call:
        a._command('rate', threading.Event(), '1M')
        assert call.call_args.args[0][-1] == '3'
    with patch('board_share.adapters.command', return_value='DAC0_CURRENT_PASS requested=30000 actual=30000'):
        with pytest.raises(RuntimeError):
            a._command('dac', threading.Event(), 32000)
    with pytest.raises(Rejected):
        a.validate({'operation': 'rate', 'parameters': {'value': '1M & arbitrary'}})
    a.config.update(bind='127.0.0.1', fpga_ip='127.0.0.2')
    a.package = {'identity': 'mock'}
    a.snapshots = None
    pytest.importorskip('host.rfudp_traffic')
    with patch.object(a, '_start_udp'), patch.object(a, '_command'), patch('host.rfudp_traffic.run_traffic', side_effect=lambda cfg, *args: cfg):
        cfg = a.execute({'operation': 'traffic', 'package': a.package,
                         'parameters': {'config': {}}}, threading.Event())
        assert cfg.bind == '127.0.0.1' and cfg.target == '127.0.0.2'
        assert Path(cfg.iperf_path) == Path('host/tools/iperf-1.7.0/iperf.exe')


def test_event_buffer_experiment_isolation():
    a = RfUdpAdapter({})
    a.event_buffer.emit('uart', 'previous-owner')
    a.begin_experiment()
    assert not a.events(0)['events']


@pytest.fixture(scope='module')
def tcl_runtime():
    import tkinter
    return tkinter.Tcl()


@pytest.mark.parametrize('mode,value', [('identity', None), ('stop_output', None), ('start_output', None), ('lms', 6)])
def test_tcl_with_mock_registers_only(mode, value, tcl_runtime):
    t = tcl_runtime
    t.eval('''
      array set regs {0x80100000 0x56335246 0x80100004 0x04000000 0x80100008 0x6AEAAAC2 0x8010000C 0x9348B574 0x80100010 6 0x80100018 7}
      proc connect {args} {}
      proc disconnect {} {}
      proc targets {args} {
        if {$args eq "-target-properties"} {
          return [list [dict create name PSU jtag_cable_serial 15051A target_id 4]]
        }
      }
      proc configparams {args} {}
      proc mrd {args} {global regs; return [list $regs([lindex $args 2])]}
      proc mwr {args} {global regs; set regs([lindex $args 1]) [lindex $args 2]}
    ''')
    t.setvar('argv', (mode, '15051A') if value is None else (mode, '15051A', str(value)))
    t.eval(Path(__file__).with_name('rfudp_control.tcl').read_text(encoding='utf-8'))
    if mode == 'stop_output':
        assert int(t.getvar('regs(0x80100010)')) == 4
        assert int(t.getvar('regs(0x80100018)')) == 6
    elif mode == 'lms':
        assert int(t.getvar('regs(0x80100010)')) == 6


def test_tcl_waits_for_serial_properties_without_selecting_other_cable(tcl_runtime):
    t = tcl_runtime
    t.eval('''
      set attempts 0
      set delays 0
      set selected 0
      proc after {ms} {global delays; incr delays}
      proc targets {args} {
        global attempts selected
        if {$args eq "-target-properties"} {
          incr attempts
          if {$attempts < 3} {return [list [dict create name PSU target_id 4]]}
          return [list [dict create name PSU target_id 4 jtag_cable_serial 15051A]]
        }
        set selected [lindex $args 1]
      }
    ''')
    t.setvar('argv', ('identity', '15051A'))
    t.eval(Path(__file__).with_name('rfudp_control.tcl').read_text(encoding='utf-8'))
    assert int(t.getvar('delays')) == 2
    assert int(t.getvar('selected')) == 4
    t.eval('set selected 0; set delays 0')
    t.setvar('argv', ('identity', 'OTHER'))
    import tkinter
    with pytest.raises(tkinter.TclError, match='Expected one PSU'):
        t.eval(Path(__file__).with_name('rfudp_control.tcl').read_text(encoding='utf-8'))
    assert int(t.getvar('selected')) == 0
    assert int(t.getvar('delays')) == 10
