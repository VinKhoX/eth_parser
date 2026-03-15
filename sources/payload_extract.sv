// =============================================================================
// Simplified payload_extract: 802.1Q parsing, no CRC. Valid / invalid counts only.
// Frame: [6B DA][6B SA][2B TPID][2B TCI][2B EtherType][N payload][4B FCS]
// Valid = TPID 0x8100, VID 0 or 1, frame_len >= 22, no rx_err.
// Invalid = truncated, rx_err, or non-VLAN (TPID != 0x8100). VID > 1 = silent drop.
// =============================================================================

module payload_extract #(
    parameter MAX_PKT = 2048
)(
    input  wire        clk,
    input  wire        rst,

    input  wire        rx_valid,
    input  wire [7:0]  rx_data,
    input  wire        rx_err,

    output reg  [1:0]  fifo_wen,
    output reg  [7:0]  raw_payload,

    output reg  [15:0] valid_pkt_cnt,
    output reg  [15:0] invalid_pkt_cnt
);


endmodule
