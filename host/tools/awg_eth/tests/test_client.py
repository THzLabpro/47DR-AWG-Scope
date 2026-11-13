from awg_eth import protocol
from awg_eth.awg import Awg, REG_TX_WR_CH, REG_TX_WR_PTR
from awg_eth.client import AwgEthClient, AwgEthError
from awg_eth.fpga_emu import FpgaEmulator


def test_client_block_roundtrip_ping_info_and_control_serialization():
    with FpgaEmulator().start() as emulator:
        with AwgEthClient("127.0.0.1", port=emulator.port, words_per_packet=17, window=4) as client:
            client.ping()
            info = client.info()
            assert info["awg_id"] == 0x41574531
            assert info["max_words"] == protocol.MAX_WORDS
            values = [index * 0x1020304 for index in range(75)]
            client.write_block(0x70000000, values)
            assert client.read_block(0x70000000, len(values)) == [v & 0xFFFFFFFF for v in values]

            client.write32(REG_TX_WR_CH, 0)
            client.write_block(0x90200038, values, noinc=True)
            assert client.read32(REG_TX_WR_PTR) == len(values) * 2
            assert emulator.counters["axi_words"] >= len(values) * 2 + 2


def test_loss_duplicate_injection_retries_same_write_sequence():
    with FpgaEmulator(drop_rate=0.1, duplicate_rate=0.1, seed=7).start() as emulator:
        with AwgEthClient("127.0.0.1", port=emulator.port, timeout=0.01, retries=5,
                          words_per_packet=11, window=4) as client:
            client.write32(REG_TX_WR_CH, 2)
            client.write_block(0x90200038, range(100), noinc=True)
            assert client.read32(REG_TX_WR_PTR) == 200
            assert emulator.counters["dup_writes"] > 0


def test_status_errors_include_status_index_and_address():
    with FpgaEmulator().start() as emulator:
        with AwgEthClient("127.0.0.1", port=emulator.port) as client:
            try:
                client.read32(0x90200058)
            except AwgEthError as exc:
                assert exc.status == protocol.STATUS_AXI_ERR
                assert exc.err_index == 0
                assert exc.address == 0x90200058
            else:
                raise AssertionError("unmapped register did not return AXI_ERR")
