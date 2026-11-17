"""Explicit service entry. Reading/sealing a configuration does not touch hardware."""
import argparse
import hashlib
import json
import os
from contextlib import contextmanager
from pathlib import Path
import sys
from .coordinator import Catalog, Coordinator
from .adapters import AwgAdapter, RfUdpAdapter
from .service import Service


@contextmanager
def exclusive_state(path):
    """Reject a second service before it can reconcile or operate the same board."""
    lock = Path(str(path) + '.lock')
    lock.parent.mkdir(parents=True, exist_ok=True)
    stream = lock.open('a+b')
    try:
        stream.write(b'\0')
        stream.flush()
        stream.seek(0)
        if os.name == 'nt':
            import msvcrt
            msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl
            fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        stream.close()
        raise RuntimeError('同一状态文件已有服务运行；不能启动第二个控制实例') from None
    try:
        yield
    finally:
        stream.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True)
    parser.add_argument('--check', action='store_true', help='只检查配置和文件哈希，不启动服务或硬件')
    parser.add_argument('--seal', metavar='OUTPUT', help='为管理员列出的完整文件清单计算哈希，写入新配置')
    args = parser.parse_args()
    config = json.loads(Path(args.config).read_text(encoding='utf-8-sig'))
    if args.seal:
        for package in config['packages'].values():
            package['files'] = {str(Path(p).resolve()): hashlib.sha256(Path(p).read_bytes()).hexdigest()
                                for p in package['files']}
        with Path(args.seal).open('x', encoding='utf-8') as stream:
            json.dump(config, stream, ensure_ascii=False, indent=2)
        return
    catalog = Catalog(config['packages'])
    for key in config['packages']:
        catalog.resolve(key)
    if args.check:
        print('CONFIG_HASH_CHECK_PASS; hardware not accessed')
        return
    for path in config.get('python_paths', []):
        sys.path.insert(0, path)
    adapters = {project: {'47DR': AwgAdapter, 'RF-UDP': RfUdpAdapter}[project](settings)
                for project, settings in config['adapters'].items()}
    with exclusive_state(config['state_file']):
        coordinator = Coordinator(config['state_file'], adapters, catalog)
        try:
            with Service((config['bind'], config.get('port', 4749)), coordinator) as server:
                coordinator.start()
                server.serve_forever()
        finally:
            coordinator.close()


if __name__ == '__main__':
    main()
