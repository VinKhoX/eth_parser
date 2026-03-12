// =============================================================================
// Top file, 
// =============================================================================

module eth_parser (
    input  wire        clk,
    input  wire        rst,

    // RX byte stream
    input  wire        rx_valid,
    input  wire [7:0]  rx_data,
    input  wire        rx_err,

    // VLAN-demux FIFO write interface
    output wire [1:0]  fifo_wen,
    output wire [7:0]  raw_payload,

    // Statistics
    output wire [15:0] crc_err_cnt,
    output wire [15:0] pkt_err_cnt,
    output wire [15:0] vlan_err_cnt,
    output wire [15:0] valid_pkt_cnt
);

// ---------------------------------------------------------------------------
// Internal wires 
// ---------------------------------------------------------------------------
wire        crc_init;       
wire [7:0]  crc_data;       
wire        crc_vld;        
wire [31:0] crc_computed;   

// ---------------------------------------------------------------------------
// payload_extract instance
// ---------------------------------------------------------------------------
payload_extract #(
) u_extract_payload (
);

// ---------------------------------------------------------------------------
// crc32 instance
// ---------------------------------------------------------------------------
crc32 u_crc32 (
);

endmodule

