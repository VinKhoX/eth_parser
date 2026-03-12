"""
Test list
---------
TC01  valid VLAN-ID 0 frame              valid_pkt_cnt=1
TC02  valid VLAN-ID 1 frame              valid_pkt_cnt=1
TC03  non-VLAN frame                     silently dropped – all counters 0
TC04  VLAN frame VID=5                   silently dropped – all counters 0
TC05  bad FCS, VLAN-ID 0                 crc_err_cnt=1
TC06  rx_err mid-packet                  pkt_err_cnt=1
TC07  truncated in S_HEADER              pkt_err_cnt=1
TC08  truncated in S_VLAN                vlan_err_cnt=1, pkt_err_cnt=1
TC09  fifo_wen routes VID-0→[0], VID-1→[1]
TC10  back-to-back VLAN-0 + VLAN-1      valid_pkt_cnt=2
TC11  mixed sequence                     each counter individually correct
TC12  reset mid-packet                   counters cleared; next frame counts
TC13  VLAN-ID 2 dropped                  all counters 0
TC14  5 consecutive valid VLAN-0 frames  valid_pkt_cnt=5
TC15  standard LE FCS (byte-order note)  crc_err_cnt=1
"""

from __future__ import annotations

import os
import struct
import zlib
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from cocotb_tools.runner import get_runner

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
CLK_NS  = 10    # 100 MHz
DA      = bytes([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
SA      = bytes([0x11, 0x22, 0x33, 0x44, 0x55, 0x66])
ETYPE   = bytes([0x08, 0x00])
PAYLOAD = bytes(range(0x00, 0x20))   # 32-byte incrementing payload

# ---------------------------------------------------------------------------
# Frame helpers
# ---------------------------------------------------------------------------

def eth_crc32(data: bytes) -> int:
    return zlib.crc32(data) & 0xFFFF_FFFF


def build_vlan_frame(vid: int, payload: bytes) -> bytes:
    """DA + SA + TPID(0x8100) + TCI + EType + Payload  (no FCS)."""
    return (DA + SA
            + b'\x81\x00'
            + struct.pack('>H', vid & 0x0FFF)
            + ETYPE
            + payload)


def build_plain_frame(payload: bytes) -> bytes:
    """Non-VLAN frame body (no FCS)."""
    return DA + SA + ETYPE + payload


def append_fcs_be(body: bytes) -> bytes:
    """Append CRC32 big-endian (MSB first) – matches RTL rx_crc_captured."""
    return body + struct.pack('>I', eth_crc32(body))


def append_fcs_le(body: bytes) -> bytes:
    """Standard Ethernet FCS (little-endian LSB first)."""
    return body + struct.pack('<I', eth_crc32(body))


# ---------------------------------------------------------------------------
# Driver / helper coroutines
# ---------------------------------------------------------------------------

async def do_reset(dut):
    dut.rst.value      = 1
    dut.rx_valid.value = 0
    dut.rx_data.value  = 0
    dut.rx_err.value   = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def drive_frame(dut, data: bytes, err_at: int = -1):
    """Stream bytes byte-by-byte; deassert rx_valid one cycle after (EOP)."""
    for i, b in enumerate(data):
        dut.rx_valid.value = 1
        dut.rx_data.value  = int(b)
        dut.rx_err.value   = 1 if i == err_at else 0
        await RisingEdge(dut.clk)
    dut.rx_valid.value = 0
    dut.rx_data.value  = 0
    dut.rx_err.value   = 0
    await RisingEdge(dut.clk)   # EOP cycle


async def settle(dut, n: int = 5):
    """Wait n cycles for FSM CRC + replay to complete."""
    for _ in range(n):
        await RisingEdge(dut.clk)


def assert_counters(dut, valid=0, crc=0, pkt=0, vlan=0, msg=""):
    prefix = f"[{msg}] " if msg else ""
    assert int(dut.valid_pkt_cnt.value) == valid, \
        f"{prefix}valid_pkt_cnt: got {int(dut.valid_pkt_cnt.value)}, want {valid}"
    assert int(dut.crc_err_cnt.value) == crc, \
        f"{prefix}crc_err_cnt: got {int(dut.crc_err_cnt.value)}, want {crc}"
    assert int(dut.pkt_err_cnt.value) == pkt, \
        f"{prefix}pkt_err_cnt: got {int(dut.pkt_err_cnt.value)}, want {pkt}"
    assert int(dut.vlan_err_cnt.value) == vlan, \
        f"{prefix}vlan_err_cnt: got {int(dut.vlan_err_cnt.value)}, want {vlan}"


REPLAY_SETTLE = len(PAYLOAD) + 10   # cycles to let replay phase finish

# ===========================================================================
# Tests
# ===========================================================================

@cocotb.test()
async def tc01_valid_vlan0(dut):
    """Good VLAN-ID 0 frame → valid_pkt_cnt=1, all error counters 0."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    await do_reset(dut)

    await drive_frame(dut, append_fcs_be(build_vlan_frame(0, PAYLOAD)))
    await settle(dut, REPLAY_SETTLE)
    assert_counters(dut, valid=1, msg="TC01")


@cocotb.test()
async def tc02_valid_vlan1(dut):
    """Good VLAN-ID 1 frame → valid_pkt_cnt=1, all error counters 0."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    await do_reset(dut)

    await drive_frame(dut, append_fcs_be(build_vlan_frame(1, PAYLOAD)))
    await settle(dut, REPLAY_SETTLE)
    assert_counters(dut, valid=1, msg="TC02")


@cocotb.test()
async def tc03_non_vlan_dropped(dut):
    """Plain Ethernet frame (no TPID) → all counters 0 (silent drop)."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    await do_reset(dut)

    await drive_frame(dut, append_fcs_be(build_plain_frame(PAYLOAD)))
    await settle(dut, 6)
    assert_counters(dut, msg="TC03")


@cocotb.test()
async def tc04_vlan_vid5_dropped(dut):
    """VLAN-ID 5 (VID > 1) → all counters 0 (silent drop)."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    await do_reset(dut)

    await drive_frame(dut, append_fcs_be(build_vlan_frame(5, PAYLOAD)))
    await settle(dut, 6)
    assert_counters(dut, msg="TC04")


@cocotb.test()
async def tc05_bad_fcs(dut):
    """VLAN-ID 0 frame with corrupted FCS → crc_err_cnt=1."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    await do_reset(dut)

    bad = build_vlan_frame(0, PAYLOAD) + b'\xDE\xAD\xBE\xEF'
    await drive_frame(dut, bad)
    await settle(dut, 6)
    assert_counters(dut, crc=1, msg="TC05")


@cocotb.test()
async def tc06_rx_err(dut):
    """rx_err asserted at byte 20 → pkt_err_cnt=1 (shadows CRC check)."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    await do_reset(dut)

    frame = append_fcs_be(build_vlan_frame(0, PAYLOAD))
    await drive_frame(dut, frame, err_at=20)
    await settle(dut, 6)
    assert_counters(dut, pkt=1, msg="TC06")


@cocotb.test()
async def tc07_truncated_header(dut):
    """Frame ends after 5 bytes (S_HEADER) → pkt_err_cnt=1."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    await do_reset(dut)

    body = build_vlan_frame(0, PAYLOAD)
    await drive_frame(dut, body[:5])
    await settle(dut, 6)
    assert_counters(dut, pkt=1, msg="TC07")


@cocotb.test()
async def tc08_truncated_vlan(dut):
    """Frame truncated at byte 15 (inside S_VLAN) → vlan_err=1, pkt_err=1."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    await do_reset(dut)

    body = build_vlan_frame(0, PAYLOAD)
    await drive_frame(dut, body[:15])
    await settle(dut, 6)
    assert_counters(dut, pkt=1, vlan=1, msg="TC08")


@cocotb.test()
async def tc09_fifo_wen_routing(dut):
    """fifo_wen[0] fires for VID-0, fifo_wen[1] fires for VID-1."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    await do_reset(dut)

    for vid, bit in [(0, 0), (1, 1)]:
        pl = bytes(range(10 + vid * 10, 20 + vid * 10))
        frame = append_fcs_be(build_vlan_frame(vid, pl))
        seen = [[], []]

        async def capture(v=vid, s=seen):
            while True:
                await RisingEdge(dut.clk)
                w = int(dut.fifo_wen.value)
                if w & 0x1:
                    s[0].append(int(dut.raw_payload.value))
                if w & 0x2:
                    s[1].append(int(dut.raw_payload.value))

        mon = cocotb.start_soon(capture())
        await drive_frame(dut, frame)
        await settle(dut, len(pl) + 10)
        mon.kill()

        assert seen[bit]     == list(pl), f"VID-{vid}: payload on [{ bit}] wrong"
        assert seen[1 - bit] == [],       f"VID-{vid}: wrong FIFO port fired"

    assert_counters(dut, valid=2, msg="TC09")


@cocotb.test()
async def tc10_back_to_back(dut):
    """VLAN-0 then VLAN-1 back-to-back → valid_pkt_cnt=2."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    await do_reset(dut)

    f0 = append_fcs_be(build_vlan_frame(0, PAYLOAD))
    f1 = append_fcs_be(build_vlan_frame(1, PAYLOAD))

    await drive_frame(dut, f0)
    await settle(dut, REPLAY_SETTLE)
    await drive_frame(dut, f1)
    await settle(dut, REPLAY_SETTLE)
    assert_counters(dut, valid=2, msg="TC10")


@cocotb.test()
async def tc11_mixed_sequence(dut):
    """
    1. valid VID-0      → valid=1
    2. bad FCS VID-1    → crc=1
    3. non-VLAN         → no change
    4. rx_err VID-0     → pkt=1
    5. truncated VLAN   → vlan=1 pkt=2
    6. valid VID-1      → valid=2
    """
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    await do_reset(dut)

    g0 = append_fcs_be(build_vlan_frame(0, PAYLOAD))
    g1 = append_fcs_be(build_vlan_frame(1, PAYLOAD))

    await drive_frame(dut, g0);                       await settle(dut, REPLAY_SETTLE)
    assert_counters(dut, valid=1, msg="after pkt1")

    await drive_frame(dut, build_vlan_frame(1, PAYLOAD) + b'\xCA\xFE\xBA\xBE')
    await settle(dut, 6)
    assert_counters(dut, valid=1, crc=1, msg="after pkt2")

    await drive_frame(dut, append_fcs_be(build_plain_frame(PAYLOAD)))
    await settle(dut, 6)
    assert_counters(dut, valid=1, crc=1, msg="after pkt3")

    await drive_frame(dut, g0, err_at=25);            await settle(dut, 6)
    assert_counters(dut, valid=1, crc=1, pkt=1, msg="after pkt4")

    await drive_frame(dut, build_vlan_frame(0, PAYLOAD)[:15])
    await settle(dut, 6)
    assert_counters(dut, valid=1, crc=1, pkt=2, vlan=1, msg="after pkt5")

    await drive_frame(dut, g1);                       await settle(dut, REPLAY_SETTLE)
    assert_counters(dut, valid=2, crc=1, pkt=2, vlan=1, msg="after pkt6")


@cocotb.test()
async def tc12_reset_mid_packet(dut):
    """Mid-packet reset → counters 0; next good frame counted correctly."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    await do_reset(dut)

    frame = append_fcs_be(build_vlan_frame(0, PAYLOAD))
    for b in frame[: len(frame) // 2]:
        dut.rx_valid.value = 1
        dut.rx_data.value  = int(b)
        dut.rx_err.value   = 0
        await RisingEdge(dut.clk)

    dut.rst.value = 1;  dut.rx_valid.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)

    assert_counters(dut, msg="TC12 post-reset")

    await drive_frame(dut, frame)
    await settle(dut, REPLAY_SETTLE)
    assert_counters(dut, valid=1, msg="TC12 after recovery")


@cocotb.test()
async def tc13_vlan_id2_dropped(dut):
    """VLAN-ID 2 (VID > 1) → silently dropped, all counters 0."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    await do_reset(dut)

    await drive_frame(dut, append_fcs_be(build_vlan_frame(2, PAYLOAD)))
    await settle(dut, 6)
    assert_counters(dut, msg="TC13")


@cocotb.test()
async def tc14_five_valid_frames(dut):
    """5 consecutive valid VLAN-0 frames → valid_pkt_cnt=5."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    await do_reset(dut)

    frame = append_fcs_be(build_vlan_frame(0, PAYLOAD))
    for _ in range(5):
        await drive_frame(dut, frame)
        await settle(dut, REPLAY_SETTLE)
    assert_counters(dut, valid=5, msg="TC14")


@cocotb.test()
async def tc15_le_fcs_byteorder_note(dut):
    """Standard LE FCS → crc_err_cnt=1 (documents RTL byte-order assumption)."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    await do_reset(dut)

    await drive_frame(dut, append_fcs_le(build_vlan_frame(0, PAYLOAD)))
    await settle(dut, 6)
    assert int(dut.crc_err_cnt.value) == 1, (
        "TC15: standard LE FCS should cause crc_err in the current RTL. "
        f"crc_err_cnt={dut.crc_err_cnt.value}  valid_pkt_cnt={dut.valid_pkt_cnt.value}"
    )


# ===========================================================================
# Runner (pytest / direct-python entry-point)
# ===========================================================================
def test_eth_parser_runner():
    sim       = os.getenv("SIM", "icarus")
    test_dir  = Path(__file__).resolve().parent
    proj_path = test_dir.parent
    src_dir   = proj_path / "sources"

    sources  = [
        src_dir / "crc32.v",
        src_dir / "payload_extract.sv",
        src_dir / "eth_parser.sv",
    ]

    runner = get_runner(sim)
    runner.build(
        sources=sources,
        hdl_toplevel="eth_parser",
        always=True,
        waves=True,
        timescale=("1ns","1ps"),
    )
    runner.test(
        hdl_toplevel="eth_parser",
        test_module="test_eth_parser",
        plusargs=["+dump_file=eth_parser.fst"],
    )


if __name__ == "__main__":
    test_eth_parser_runner()
