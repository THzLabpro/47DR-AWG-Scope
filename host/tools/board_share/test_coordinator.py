import hashlib
import threading
import pytest
from .coordinator import Catalog, Coordinator, Rejected
from .service import Service
from .session import Session


class Adapter:
    def __init__(self):
        self.calls = []
        self.clean = True
        self.fail = False

    def validate(self, task):
        if task['operation'] not in ('recover', 'test'):
            raise Rejected('unknown operation')

    def execute(self, task, cancel):
        self.calls.append(task)
        if self.fail:
            raise RuntimeError('failed test')
        return task['parameters']

    def recover(self, package, cancel):
        return {'initialized': True}

    def verify(self):
        return {'responsive': True, 'verified_project': '47DR'}

    def cleanup(self):
        return self.clean


@pytest.fixture
def setup(tmp_path):
    bit = tmp_path / 'bit'
    bit.write_bytes(b'version1')
    catalog = Catalog({'f3': {'project': '47DR', 'files': {str(bit): hashlib.sha256(bit.read_bytes()).hexdigest()}}})
    adapter = Adapter()
    now = [100.0]
    c = Coordinator(tmp_path / 'state.db', {'47DR': adapter}, catalog, lambda: now[0])
    a = c.register('张三')['token']
    b = c.register('李四')['token']
    c.act('recover', a, dict(project='47DR', package='f3', confirmed=True))
    c.tick()
    yield c, adapter, a, b, now, bit
    c.close()


def submit(c, token, parameters=None, **kw):
    return c.act('submit', token, dict(project='47DR', operation='test', parameters=parameters or {}, package='f3', switch=True, **kw))['id']


def test_fifo_frozen_whole_experiment(setup):
    c, adapter, a, b, *_ = setup
    params = {'values': [1, 2]}
    job = submit(c, b, params, enqueue=True)
    params['values'][0] = 999
    c.tick()
    assert not adapter.calls
    assert c.status(b)['owner']['name'] == '张三'
    c.act('end', a, {})
    c.tick()  # cleanup
    c.tick()  # automatic dispatch; no second start
    assert c.act('result', b, {'id': job})['result'] == {'values': [1, 2]}
    assert c.status(b)['mine']  # no auto-release after operation


def test_busy_requires_explicit_queue_and_one_pending(setup):
    c, _, a, b, *_ = setup
    with pytest.raises(Rejected):
        submit(c, b)
    submit(c, b, enqueue=True)
    with pytest.raises(Rejected):
        submit(c, b, enqueue=True)
    c.act('cancel', b, {})
    assert c.status(a)['queue'] == []


def test_cleanup_failure_blocks_handoff(setup):
    c, adapter, a, b, *_ = setup
    submit(c, b, enqueue=True)
    adapter.clean = False
    c.act('end', a, {})
    c.tick()
    c.tick()
    assert c.status(a)['phase'] == 'recovery'
    assert not adapter.calls


def test_grace_and_expiry(setup):
    c, _, a, b, now, _ = setup
    job = submit(c, b, enqueue=True)
    now[0] += 29
    c.tick()
    assert c.status(a)['mine']
    now[0] += 2
    c.tick()
    assert c.status(a)['owner'] is None
    assert c.act('result', b, {'id': job})['state'] == 'cancelled'


def test_reconnect_and_firmware_change(setup):
    c, adapter, a, b, now, bit = setup
    submit(c, b, enqueue=True)
    now[0] += 29
    c.act('heartbeat', a, {})
    c.act('heartbeat', b, {})
    now[0] += 2
    c.tick()
    assert c.status(a)['mine']
    bit.write_bytes(b'changed')
    c.act('end', a, {})
    c.tick()
    c.tick()
    assert c.status(b)['phase'] == 'recovery'
    assert not adapter.calls


def test_no_replay_on_restart(setup, tmp_path):
    c, adapter, a, b, *_ = setup
    job = submit(c, b, enqueue=True)
    other = Coordinator(tmp_path / 'state.db', {'47DR': adapter}, c.catalog)
    try:
        assert other.status(b)['phase'] == 'recovery'
        assert other.act('result', b, {'id': job})['state'] == 'cancelled'
        other.tick()
        assert not adapter.calls
    finally:
        other.close()


def test_result_identity_isolation(setup):
    c, _, a, b, *_ = setup
    job = submit(c, b, enqueue=True)
    with pytest.raises(Rejected):
        c.act('result', a, {'id': job})


def test_http_identity_persistence(setup, tmp_path):
    c, *_ = setup
    server = Service(('127.0.0.1', 0), c)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    url = f'http://127.0.0.1:{server.server_port}'
    try:
        s = Session(url, tmp_path / 'identity.json')
        s.identify('王五')
        assert s.call('status')['name'] == '王五'
        restored = Session(url, s.path)
        assert restored.token == s.token
        restored.identify('王六')
        assert restored.call('status')['name'] == '王六'
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


def test_end_cancels_inflight_before_handoff(setup):
    c, adapter, a, b, *_ = setup
    started = threading.Event()
    stopped = threading.Event()
    def execute(task, cancel):
        started.set()
        assert cancel.wait(3)
        stopped.set()
        return {}
    adapter.execute = execute
    job = submit(c, a)
    submit(c, b, enqueue=True)
    worker = threading.Thread(target=c.tick)
    worker.start()
    assert started.wait(2)
    c.act('end', a, {})
    assert c.status(b)['owner']['name'] == '张三'
    worker.join(3)
    assert stopped.is_set()
    assert c.act('result', a, {'id': job})['state'] == 'cancelled'
    assert c.status(b)['phase'] == 'closing'
    c.tick()
    assert c.status(b)['owner'] is None


@pytest.mark.parametrize('clean', [True, False])
def test_exception_on_cancel_hands_off_only_after_verified_cleanup(setup, clean):
    c, adapter, a, b, *_ = setup
    started = threading.Event()
    def execute(task, cancel):
        started.set()
        assert cancel.wait(3)
        raise RuntimeError('operation cancelled')
    adapter.execute = execute
    adapter.clean = clean
    own_job = submit(c, a)
    next_job = submit(c, b, enqueue=True)
    worker = threading.Thread(target=c.tick)
    worker.start()
    assert started.wait(2)
    c.act('end', a, {})
    worker.join(3)
    assert not worker.is_alive()
    assert c.status(b)['phase'] == ('ready' if clean else 'recovery')
    assert c.act('result', a, {'id': own_job})['state'] == ('cancelled' if clean else 'failed')
    adapter.execute = lambda task, cancel: {'next': True}
    c.tick()
    assert c.act('result', b, {'id': next_job})['state'] == ('done' if clean else 'queued')


def test_expired_owner_can_be_recovered_and_submit_cannot_bypass_confirm(setup):
    c, adapter, a, b, now, _ = setup
    adapter.clean = False
    c.act('end', a, {})
    c.tick()
    with pytest.raises(Rejected):
        c.act('submit', b, dict(project='47DR', package='f3', operation='recover', switch=True))
    now[0] += 31
    c.act('heartbeat', b, {})
    assert c.status(b)['can_recover']
    c.act('recover', b, dict(project='47DR', package='f3', confirmed=True))
    c.tick()
    assert c.status(b)['mine']
    assert c.status(b)['phase'] == 'owned'


def test_second_service_is_rejected_before_state_changes(tmp_path):
    from .lab_service import exclusive_state
    path = tmp_path / 'single.db'
    with exclusive_state(path):
        with pytest.raises(RuntimeError, match='第二个'):
            with exclusive_state(path):
                raise AssertionError('second service entered')
    with exclusive_state(path):
        pass


def test_owner_can_explicitly_recover_into_other_project(setup):
    c, adapter, a, b, now, bit = setup
    rf = Adapter()
    rf.verify = lambda: {'responsive': True, 'verified_project': 'RF-UDP'}
    c.adapters['RF-UDP'] = rf
    c.catalog = Catalog({
        'f3': {'project': '47DR', 'files': {str(bit): hashlib.sha256(bit.read_bytes()).hexdigest()}},
        'rf': {'project': 'RF-UDP', 'files': {str(bit): hashlib.sha256(bit.read_bytes()).hexdigest()}},
    })
    with pytest.raises(Rejected, match='先结束'):
        c.act('submit', a, dict(project='RF-UDP', package='rf', operation='test', switch=True))
    adapter.clean = False
    c.act('end', a, {})
    c.tick()
    with pytest.raises(Rejected, match='明确确认'):
        c.act('recover', a, dict(project='RF-UDP', package='rf'))
    c.act('recover', a, dict(project='RF-UDP', package='rf', confirmed=True))
    c.tick()
    assert c.status(a)['phase'] == 'owned'
    assert c.status(a)['project'] == 'RF-UDP'
    assert c.status(a)['mine']
