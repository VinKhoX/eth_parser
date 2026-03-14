// =============================================================================
// Module  : payload_extract
// Purpose : Parse Ethernet frames, filter by 802.1Q VLAN-ID (0 or 1),
//           validate CRC-32, then replay buffered payload to the FIFO port
//           that corresponds to the packet's VLAN-ID.
//
// Frame layout (bytes on wire):
//   [6B DA][6B SA][2B TPID=0x8100][2B TCI][2B inner-EType][N B Payload][4B FCS]
//   Non-VLAN frames and VLAN-ID > 1 are silently dropped.
//
// fifo_wen encoding (post-CRC, during S_REPLAY only):
//   fifo_wen[0] = 1  →  payload byte belongs to VLAN-ID 0
//   fifo_wen[1] = 1  →  payload byte belongs to VLAN-ID 1
//
// External CRC32 interface:
//   crc_init  (wire out) – pulse high at SOP to reset crc32 accumulator
//   crc_data  (reg  out) – byte being hashed (DA through end-of-payload)
//   crc_vld   (reg  out) – qualifies crc_data
//   crc_computed (in)   – residue from crc32 module (compare at S_CRC)
// =============================================================================

module payload_extract #(
    parameter MAX_PKT = 2048   // internal payload buffer depth (bytes)
)(
    input  wire        clk,
    input  wire        rst,

    // RX byte stream
    input  wire        rx_valid,
    input  wire [7:0]  rx_data,
    input  wire        rx_err,

    // External CRC32 sidecar
    output wire        crc_init,        // = SOP (wire, not registered)
    output reg  [7:0]  crc_data,
    output reg         crc_vld,
    input  wire [31:0] crc_computed,

    // VLAN-demux FIFO write interface (valid only during S_REPLAY)
    output reg  [1:0]  fifo_wen,
    output reg  [7:0]  raw_payload,

    // Statistics counters
    output reg  [15:0] crc_err_cnt,
    output reg  [15:0] pkt_err_cnt,
    output reg  [15:0] vlan_err_cnt,
    output reg  [15:0] valid_pkt_cnt
);
endmodule
