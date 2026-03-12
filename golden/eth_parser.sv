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
    .MAX_PKT (2048)
) u_extract_payload (
    .clk          (clk),
    .rst          (rst),

    .rx_valid     (rx_valid),
    .rx_data      (rx_data),
    .rx_err       (rx_err),

    // CRC32 sidecar outputs
    .crc_init     (crc_init),
    .crc_data     (crc_data),
    .crc_vld      (crc_vld),

    // CRC32 result (fed back from u_crc32)
    .crc_computed (crc_computed),

    // FIFO demux
    .fifo_wen     (fifo_wen),
    .raw_payload  (raw_payload),

    // Stats
    .crc_err_cnt  (crc_err_cnt),
    .pkt_err_cnt  (pkt_err_cnt),
    .vlan_err_cnt (vlan_err_cnt),
    .valid_pkt_cnt(valid_pkt_cnt)
);

// ---------------------------------------------------------------------------
// crc32 instance
// ---------------------------------------------------------------------------
crc32 u_crc32 (
    .clk      (clk),
    .rst      (rst),
    .init     (crc_init),
    .data_in  (crc_data),
    .data_vld (crc_vld),
    .crc_out  (crc_computed)
);

// Vinay: verify this creates dumps properly
`ifdef COCOTB_SIM
initial begin
  $dumpfile("eth_parser.vcd");
  $dumpvars(0, eth_parser);
end
`endif

endmodule

