"""
Testbench for simplified eth_parser (valid_pkt_cnt + invalid_pkt_cnt only).
Builds from golden/ (no CRC). DUT: eth_parser with payload_extract only.
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
CLK_NS  = 10
DA      = bytes([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
SA      = bytes([0x11, 0x22, 0x33, 0x44, 0x55, 0x66])
ETYPE   = bytes([0x08, 0x00])
PAYLOAD = bytes(range(0x00, 0x20))

# ---------------------------------------------------------------------------
# Frame helpers
# ---------------------------------------------------------------------------
def build_vlan_frame(vid: int, payload: bytes) -> bytes:
    return DA + SA + b'\x81\x00' + struct.pack('>H', vid & 0x0FFF) + ETYPE + payload


def build_plain_frame(payload: bytes) -> bytes:
    return DA + SA + ETYPE + payload


def append_fcs(body: bytes) -> bytes:
    crc = zlib.crc32(body) & 0xFFFF_FFFF
    return body + struct.pack('>I', crc)


# ---------------------------------------------------------------------------
# Driver / helpers
# ---------------------------------------------------------------------------
async def do_reset(dut):
    dut.rst.value = 1
    dut.rx_valid.value = 0
    dut.rx_data.value = 0
    dut.rx_err.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def drive_frame(dut, data: bytes, err_at: int = -1):
    for i, b in enumerate(data):
        dut.rx_valid.value = 1
        dut.rx_data.value = int(b)
        dut.rx_err.value = 1 if i == err_at else 0
        await RisingEdge(dut.clk)
    dut.rx_valid.value = 0
    dut.rx_data.value = 0
    dut.rx_err.value = 0
    await RisingEdge(dut.clk)


async def settle(dut, n: int = 5):
    for _ in range(n):
        await RisingEdge(dut.clk)


def assert_counters(dut, valid=0, invalid=0, msg=""):
    prefix = f"[{msg}] " if msg else ""
    assert int(dut.valid_pkt_cnt.value) == valid, \
        f"{prefix}valid_pkt_cnt: got {int(dut.valid_pkt_cnt.value)}, want {valid}"
    assert int(dut.invalid_pkt_cnt.value) == invalid, \
        f"{prefix}invalid_pkt_cnt: got {int(dut.invalid_pkt_cnt.value)}, want {invalid}"


REPLAY_SETTLE = len(PAYLOAD) + 10

def build_truncated_vlan_vid0() -> bytes:
    """802.1Q start but EOP before full header+FCS (17 bytes) — truncated, invalid."""
    return DA + SA + b'\x81\x00' + struct.pack('>H', 0) + b'\x08'

# ===========================================================================
# Tests (5 cases: valid VID 0/1, invalid, silent drop, FIFO routing)
# ===========================================================================

@cocotb.test()
async def test_valid_vlan0(dut):
    """Valid VLAN-ID 0 → valid=1."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    await do_reset(dut)
    await drive_frame(dut, append_fcs(build_vlan_frame(0, PAYLOAD)))
    await settle(dut, REPLAY_SETTLE)
    assert_counters(dut, valid=1, msg="valid vlan0")


@cocotb.test()
async def test_valid_vlan1(dut):
    """Valid VLAN-ID 1 → valid=1."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    await do_reset(dut)
    await drive_frame(dut, append_fcs(build_vlan_frame(1, PAYLOAD)))
    await settle(dut, REPLAY_SETTLE)
    assert_counters(dut, valid=1, msg="valid vlan1")


@cocotb.test()
async def test_non_vlan_invalid(dut):
    """Non-VLAN frame → invalid=1."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    await do_reset(dut)
    await drive_frame(dut, append_fcs(build_plain_frame(PAYLOAD)))
    await settle(dut, 6)
    assert_counters(dut, invalid=1, msg="non-vlan")


@cocotb.test()
async def test_vid5_silent_drop(dut):
    """VID 5 → silent drop, valid=0 invalid=0."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    await do_reset(dut)
    await drive_frame(dut, append_fcs(build_vlan_frame(5, PAYLOAD)))
    await settle(dut, 6)
    assert_counters(dut, msg="vid5 drop")

@cocotb.test()
async def test_truncated_vlan_invalid(dut):
    """802.1Q frame too short before EOP → invalid=1."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    await do_reset(dut)
    await drive_frame(dut, build_truncated_vlan_vid0())
    await settle(dut, 8)
    assert_counters(dut, invalid=1, msg="truncated vlan")

@cocotb.test()
async def test_rx_err_invalid(dut):
    """rx_err asserted during a VLAN frame → invalid=1 (no valid accept)."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    await do_reset(dut)
    frame = append_fcs(build_vlan_frame(0, PAYLOAD))
    err_at = len(DA) + 3
    await drive_frame(dut, frame, err_at=err_at)
    await settle(dut, REPLAY_SETTLE)
    assert_counters(dut, invalid=1, msg="rx_err")

@cocotb.test()
async def test_fifo_routing(dut):
    """fifo_wen[0] for VID 0, fifo_wen[1] for VID 1; payload matches."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    await do_reset(dut)
    for vid, bit in [(0, 0), (1, 1)]:
        pl = bytes(range(10 + vid * 10, 20 + vid * 10))
        frame = append_fcs(build_vlan_frame(vid, pl))
        seen = [[], []]

        async def capture(v=vid, s=seen):
            while True:
                await RisingEdge(dut.clk)
                w = int(dut.fifo_wen.value)
                if w & 1:
                    s[0].append(int(dut.raw_payload.value))
                if w & 2:
                    s[1].append(int(dut.raw_payload.value))

        mon = cocotb.start_soon(capture())
        await drive_frame(dut, frame)
        await settle(dut, len(pl) + 10)
        mon.cancel()
        assert seen[bit] == list(pl), f"VID-{vid} payload wrong"
        assert seen[1 - bit] == [], f"VID-{vid} wrong FIFO"
    assert_counters(dut, valid=2, msg="fifo routing")


# ===========================================================================
# Runner. [Vinay changes 17/03]
# ===========================================================================
def test_eth_parser_runner():
    sim = os.getenv("SIM", "icarus")
    test_dir = Path(__file__).resolve().parent
    proj_path = test_dir.parent
    src_dir = proj_path / "sources"
    sources = [src_dir / "payload_extract.sv", src_dir / "eth_parser.sv"]
    runner = get_runner(sim)
    runner.build(
        sources=sources,
        hdl_toplevel="eth_parser",
        always=True,
        waves=True,
        timescale=("1ns", "1ps"),
    )
    runner.test(
        hdl_toplevel="eth_parser",
        test_module="test_eth_parser",
        plusargs=["+dump_file=eth_parser.fst"],
    )


if __name__ == "__main__":
    test_eth_parser_runner()
