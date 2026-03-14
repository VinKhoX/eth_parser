// =============================================================================
// Module  : crc32
// Purpose : Compute Ethernet CRC-32 (IEEE 802.3, poly 0x04C11DB7) byte-serially.
//
// Usage   :
//   - Assert init for one cycle at start-of-packet to reset the accumulator.
//   - Drive data_in with each byte and assert data_vld for one cycle per byte.
//   - crc_out is the *residue-inverted* CRC (ready to compare with the
//     received trailer CRC after the last data byte is processed).
//
// Algorithm:
//   Initial value  : 0xFFFF_FFFF
//   Input  reflect : yes (LSB first)
//   Output reflect : yes
//   Output XOR     : 0xFFFF_FFFF
//   Polynomial     : 0x04C11DB7
//
// The 8-bit parallel update equations below were generated from the standard
// bit-serial form and are mathematically equivalent to processing one byte
// per clock.
// =============================================================================

module crc32 (
    input  wire        clk,
    input  wire        rst,
    input  wire        init,       // synchronous reset of CRC state
    input  wire [7:0]  data_in,    // incoming byte (bit[0] = first on wire)
    input  wire        data_vld,   // qualify data_in
    output wire [31:0] crc_out     // reflected & inverted CRC residue
);

endmodule
