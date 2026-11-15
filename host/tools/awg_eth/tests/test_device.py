import pytest
from awg_eth.awg import REG_ABI, REG_BUILD_ID, REG_DAC_FS_KSPS, REG_ADC_FS_KSPS, REG_MAX_WORDS
from awg_eth.device import open_device
from awg_eth.fpga_emu import FpgaEmulator


class RecordedEmulator(FpgaEmulator):
    def __init__(self, **kwargs):
        super().__init__(abi=3, build_id=0xD4B02026, **kwargs)
        self.writes = []
        self.overrides = {}

    def _write_register(self, address, value):
        self.writes.append((address, value))
        return super()._write_register(address, value)

    def _read_register(self, address):
        if address in self.overrides:
            return True, self.overrides[address]
        return super()._read_register(address)


@pytest.mark.parametrize("register,value", [(REG_ABI, 0x40000), (REG_BUILD_ID, 1),
    (REG_DAC_FS_KSPS, 9000000), (REG_ADC_FS_KSPS, 1), (REG_MAX_WORDS, 0)])
def test_version_mismatch_never_writes(register, value):
    with RecordedEmulator() as emu:
        emu.overrides[register] = value
        with pytest.raises(ValueError, match="firmware mismatch"):
            open_device("127.0.0.1", emu.port)
        assert emu.writes == []


def test_missing_bulk_refused_without_writes(monkeypatch):
    from awg_eth.awg import Awg
    monkeypatch.setattr(Awg, "_detect_bulk", lambda self: None)
    with RecordedEmulator() as emu:
        with pytest.raises(RuntimeError, match="bulk port unavailable"):
            open_device("127.0.0.1", emu.port)
        assert emu.writes == []
