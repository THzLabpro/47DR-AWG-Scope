"""MATLAB file IPC adapter for the remote board service."""
import argparse
from pathlib import Path
import sys
import time

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from awg_eth.gui_bridge import read_fields, write_fields
from awg_eth.remote import RemoteClient


def main(session):
    peer = None
    try:
        cfg = read_fields(session / 'config.txt')
        peer = RemoteClient(cfg['remote_host'], int(cfg['remote_port']))
        peer.info['device'] = cfg['remote_host']
        peer.info['target'] = 'TCP:' + cfg['remote_port']
        write_fields(session / 'hello.res', peer.info)
        while True:
            for path in sorted(session.glob('*.req')):
                request = read_fields(path)
                action = request['action']
                try:
                    if action == 'disconnect':
                        peer.close()
                        peer = None
                        result = {'ok': 1, 'disconnected': 1}
                    else:
                        params = {k: request[k] for k in ('verify', 'samples', 'mask', 'trigger') if k in request}
                        result = peer.request(action, waveform=request.get('directory'),
                                              capture=request.get('capture'), **params)
                        if action in ('capture', 'run') or (action == 'start' and request.get('hold') != '1'):
                            peer.close()
                            peer = None
                            result['released'] = 1
                except Exception as exc:
                    result = {'ok': 0, 'message': str(exc)}
                write_fields(path.with_suffix('.res'), result)
                path.unlink(missing_ok=True)
                if peer is None:
                    return
            heartbeat = session / 'heartbeat'
            if not heartbeat.exists() or time.time() - heartbeat.stat().st_mtime > 120:
                return
            time.sleep(.05)
    except Exception as exc:
        write_fields(session / 'hello.res', {'ok': 0, 'message': str(exc)})
    finally:
        if peer is not None:
            peer.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('session', type=Path)
    main(parser.parse_args().session)
