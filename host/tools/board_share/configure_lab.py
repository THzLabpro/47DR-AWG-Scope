"""Create a sealed candidate using existing lab files, without hardware access.

No services, network settings, or running installations are changed.
"""
import argparse
import hashlib
import json
from pathlib import Path


def generate(rfroot, awgroot, xsdb, xsct, output, bind, fpga_bind, serial):
    root = Path(rfroot).resolve()
    awg = Path(awgroot).resolve()
    control = Path(__file__).with_name('rfudp_control.tcl').resolve()
    bitdir = root / 'build/v4/signoff_v4r1'
    awgpkg = awg / 'host/hardware/eth40g_v2_1'
    def hashes(files):
        return {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
    rf_files = list(bitdir.iterdir()) + list((root / 'scripts/hw').glob('*.tcl')) + list((root / 'scripts/hw').glob('*.ps1')) + [control, root / 'host/rate_mailbox.tcl', root / 'host/tools/iperf-1.7.0/iperf.exe']
    rf_files = [p for p in rf_files if p.is_file()]
    shared = {'root': str(root), 'fpga_ip': '192.168.42.2', 'bind': fpga_bind,
              'cleanup_validated': False, 'serial_port': 'COM8', 'baud': 115200}
    def cmd(script, *args):
        return ['cmd.exe', '/d', '/c', str(xsdb), str(script), *map(str, args)]
    shared['commands'] = {
        'identity': {'argv': cmd(control, 'identity', serial), 'pass': 'IDENTITY_READ_PASS'},
        'stop_output': {'argv': cmd(control, 'stop_output', serial), 'pass': 'STOP_OUTPUT_REGISTERS_PASS'},
        'start_output': {'argv': cmd(control, 'start_output', serial), 'pass': 'START_OUTPUT_REGISTERS_PASS'},
        'lms': {'argv': cmd(control, 'lms', serial, '{value}'), 'pass': 'LMS_PASS {value}'},
        'dac': {'argv': cmd(root / 'scripts/hw/dac_current_rw.tcl', '{value}'), 'pass': 'DAC0_CURRENT_PASS'},
        'rate': {'argv': cmd(root / 'host/rate_mailbox.tcl', '{value}', serial), 'pass': 'RATE_SWITCH_PASS'},
    }
    rf_program = ['powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File',
                  str(root / 'scripts/hw/program_board_v3.ps1'), '-Profile', 'v4r1', '-Program',
                  '-XsdbPath', str(xsdb), '-JtagSerial', serial, '-DacCurrentUa', '32000']
    config = {'bind': bind, 'port': 4749, 'state_file': str(root / 'host/app_data/board_share_v2.sqlite3'),
              'python_paths': [str(root), str(awg / 'host/tools')],
              'adapters': {'RF-UDP': shared, '47DR': {'root': str(awg), 'fpga_ip': '192.168.42.2', 'cleanup_validated': False}},
              'packages': {
                'RFUDP-v4r1': {'project': 'RF-UDP', 'files': hashes(rf_files), 'program': rf_program,
                    'program_pass': 'RFU_BOARD_PROGRAM_PASS',
                    'identity_markers': ['ID=0x56335246','VERSION=0x04000000','BUILD_ID=0x6AEAAAC2','SRC_HASH=0x9348B574']},
                '47DR-F3': {'project': '47DR', 'files': hashes(p for p in awgpkg.iterdir() if p.is_file()),
                    'program': ['cmd.exe', '/d', '/c', str(xsct), str(awgpkg / 'program.tcl'), '-package', str(awgpkg)],
                    'program_pass': 'RF initializer is running.'}}}
    for required in [bitdir / 'rfudp_v3_top.bit', bitdir / 'v3_uart_telemetry_v4r1.elf',
                     bitdir / 'rfudp_v3_top.xsa', awgpkg / 'rf_awg_scope_v1.bit', awgpkg / 'rf_awg_init.elf',
                     root / 'host/tools/iperf-1.7.0/iperf.exe',
                     awgpkg / 'psu_init.tcl', awgpkg / 'init_protocol.txt', Path(xsdb), Path(xsct)]:
        if not required.is_file():
            raise FileNotFoundError(required)
    with Path(output).open('x', encoding='utf-8') as f:
        json.dump(config, f, ensure_ascii=False, indent=2)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('rf-root', 'awg-root', 'xsdb', 'xsct', 'output', 'bind', 'fpga-bind'):
        p.add_argument('--' + name, required=True)
    p.add_argument('--serial', default='15051A')
    a = p.parse_args()
    generate(a.rf_root, a.awg_root, a.xsdb, a.xsct, a.output, a.bind, a.fpga_bind, a.serial)


if __name__ == '__main__':
    main()
