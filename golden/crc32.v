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

// ---------------------------------------------------------------------------
// CRC accumulator
// ---------------------------------------------------------------------------
reg [31:0] crc_reg;

// Next-state CRC computed combinationally
wire [31:0] crc_next;
wire [31:0] crc_cur = crc_reg;

// Reflect the input byte (LSB-first as per Ethernet)
wire [7:0] d = {data_in[0], data_in[1], data_in[2], data_in[3],
                data_in[4], data_in[5], data_in[6], data_in[7]};

// ---------------------------------------------------------------------------
// 8-bit parallel CRC-32 update (poly = 0x04C11DB7)
// Generated using standard XOR-folding of the bit-serial recurrence.
// Each bit of crc_next is a XOR combination of current CRC bits and d bits.
// ---------------------------------------------------------------------------
assign crc_next[0]  = crc_cur[24] ^ crc_cur[30] ^ d[0] ^ d[6];
assign crc_next[1]  = crc_cur[24] ^ crc_cur[25] ^ crc_cur[30] ^ crc_cur[31] ^ d[0] ^ d[1] ^ d[6] ^ d[7];
assign crc_next[2]  = crc_cur[24] ^ crc_cur[25] ^ crc_cur[26] ^ crc_cur[30] ^ crc_cur[31] ^ d[0] ^ d[1] ^ d[2] ^ d[6] ^ d[7];
assign crc_next[3]  = crc_cur[25] ^ crc_cur[26] ^ crc_cur[27] ^ crc_cur[31] ^ d[1] ^ d[2] ^ d[3] ^ d[7];
assign crc_next[4]  = crc_cur[24] ^ crc_cur[26] ^ crc_cur[27] ^ crc_cur[28] ^ crc_cur[30] ^ d[0] ^ d[2] ^ d[3] ^ d[4] ^ d[6];
assign crc_next[5]  = crc_cur[24] ^ crc_cur[25] ^ crc_cur[27] ^ crc_cur[28] ^ crc_cur[29] ^ crc_cur[30] ^ crc_cur[31] ^ d[0] ^ d[1] ^ d[3] ^ d[4] ^ d[5] ^ d[6] ^ d[7];
assign crc_next[6]  = crc_cur[25] ^ crc_cur[26] ^ crc_cur[28] ^ crc_cur[29] ^ crc_cur[30] ^ crc_cur[31] ^ d[1] ^ d[2] ^ d[4] ^ d[5] ^ d[6] ^ d[7];
assign crc_next[7]  = crc_cur[24] ^ crc_cur[26] ^ crc_cur[27] ^ crc_cur[29] ^ crc_cur[31] ^ d[0] ^ d[2] ^ d[3] ^ d[5] ^ d[7];
assign crc_next[8]  = crc_cur[0]  ^ crc_cur[24] ^ crc_cur[25] ^ crc_cur[27] ^ crc_cur[28] ^ d[0] ^ d[1] ^ d[3] ^ d[4];
assign crc_next[9]  = crc_cur[1]  ^ crc_cur[25] ^ crc_cur[26] ^ crc_cur[28] ^ crc_cur[29] ^ d[1] ^ d[2] ^ d[4] ^ d[5];
assign crc_next[10] = crc_cur[2]  ^ crc_cur[24] ^ crc_cur[26] ^ crc_cur[27] ^ crc_cur[29] ^ d[0] ^ d[2] ^ d[3] ^ d[5];
assign crc_next[11] = crc_cur[3]  ^ crc_cur[24] ^ crc_cur[25] ^ crc_cur[27] ^ crc_cur[28] ^ d[0] ^ d[1] ^ d[3] ^ d[4];
assign crc_next[12] = crc_cur[4]  ^ crc_cur[24] ^ crc_cur[25] ^ crc_cur[26] ^ crc_cur[28] ^ crc_cur[29] ^ crc_cur[30] ^ d[0] ^ d[1] ^ d[2] ^ d[4] ^ d[5] ^ d[6];
assign crc_next[13] = crc_cur[5]  ^ crc_cur[25] ^ crc_cur[26] ^ crc_cur[27] ^ crc_cur[29] ^ crc_cur[30] ^ crc_cur[31] ^ d[1] ^ d[2] ^ d[3] ^ d[5] ^ d[6] ^ d[7];
assign crc_next[14] = crc_cur[6]  ^ crc_cur[26] ^ crc_cur[27] ^ crc_cur[28] ^ crc_cur[30] ^ crc_cur[31] ^ d[2] ^ d[3] ^ d[4] ^ d[6] ^ d[7];
assign crc_next[15] = crc_cur[7]  ^ crc_cur[27] ^ crc_cur[28] ^ crc_cur[29] ^ crc_cur[31] ^ d[3] ^ d[4] ^ d[5] ^ d[7];
assign crc_next[16] = crc_cur[8]  ^ crc_cur[24] ^ crc_cur[28] ^ crc_cur[29] ^ d[0] ^ d[4] ^ d[5];
assign crc_next[17] = crc_cur[9]  ^ crc_cur[25] ^ crc_cur[29] ^ crc_cur[30] ^ d[1] ^ d[5] ^ d[6];
assign crc_next[18] = crc_cur[10] ^ crc_cur[26] ^ crc_cur[30] ^ crc_cur[31] ^ d[2] ^ d[6] ^ d[7];
assign crc_next[19] = crc_cur[11] ^ crc_cur[27] ^ crc_cur[31] ^ d[3] ^ d[7];
assign crc_next[20] = crc_cur[12] ^ crc_cur[28] ^ d[4];
assign crc_next[21] = crc_cur[13] ^ crc_cur[29] ^ d[5];
assign crc_next[22] = crc_cur[14] ^ crc_cur[24] ^ d[0];
assign crc_next[23] = crc_cur[15] ^ crc_cur[24] ^ crc_cur[25] ^ crc_cur[30] ^ d[0] ^ d[1] ^ d[6];
assign crc_next[24] = crc_cur[16] ^ crc_cur[25] ^ crc_cur[26] ^ crc_cur[31] ^ d[1] ^ d[2] ^ d[7];
assign crc_next[25] = crc_cur[17] ^ crc_cur[26] ^ crc_cur[27] ^ d[2] ^ d[3];
assign crc_next[26] = crc_cur[18] ^ crc_cur[24] ^ crc_cur[27] ^ crc_cur[28] ^ crc_cur[30] ^ d[0] ^ d[3] ^ d[4] ^ d[6];
assign crc_next[27] = crc_cur[19] ^ crc_cur[25] ^ crc_cur[28] ^ crc_cur[29] ^ crc_cur[31] ^ d[1] ^ d[4] ^ d[5] ^ d[7];
assign crc_next[28] = crc_cur[20] ^ crc_cur[26] ^ crc_cur[29] ^ crc_cur[30] ^ d[2] ^ d[5] ^ d[6];
assign crc_next[29] = crc_cur[21] ^ crc_cur[27] ^ crc_cur[30] ^ crc_cur[31] ^ d[3] ^ d[6] ^ d[7];
assign crc_next[30] = crc_cur[22] ^ crc_cur[28] ^ crc_cur[31] ^ d[4] ^ d[7];
assign crc_next[31] = crc_cur[23] ^ crc_cur[29] ^ d[5];

// ---------------------------------------------------------------------------
// Sequential update
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst || init)
        crc_reg <= 32'hFFFF_FFFF;
    else if (data_vld)
        crc_reg <= crc_next;
end

// ---------------------------------------------------------------------------
// Output: reflect the 32-bit accumulator and XOR with 0xFFFFFFFF
// ---------------------------------------------------------------------------
wire [31:0] crc_reflected = {crc_reg[0],  crc_reg[1],  crc_reg[2],  crc_reg[3],
                              crc_reg[4],  crc_reg[5],  crc_reg[6],  crc_reg[7],
                              crc_reg[8],  crc_reg[9],  crc_reg[10], crc_reg[11],
                              crc_reg[12], crc_reg[13], crc_reg[14], crc_reg[15],
                              crc_reg[16], crc_reg[17], crc_reg[18], crc_reg[19],
                              crc_reg[20], crc_reg[21], crc_reg[22], crc_reg[23],
                              crc_reg[24], crc_reg[25], crc_reg[26], crc_reg[27],
                              crc_reg[28], crc_reg[29], crc_reg[30], crc_reg[31]};

assign crc_out = crc_reflected ^ 32'hFFFF_FFFF;

endmodule

