// =============================================================================
// Top: simplified Ethernet parser (no CRC; valid_pkt_cnt + invalid_pkt_cnt only)
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

    // Statistics (simplified: valid and invalid only)
    output wire [15:0] valid_pkt_cnt,
    output wire [15:0] invalid_pkt_cnt
);

// ---------------------------------------------------------------------------
// payload_extract instance (no CRC submodule)
// ---------------------------------------------------------------------------
payload_extract #(
    .MAX_PKT(2048)
) u_extract_payload (
    .clk             (clk),
    .rst             (rst),
    .rx_valid        (rx_valid),
    .rx_data         (rx_data),
    .rx_err          (rx_err),
    .fifo_wen        (fifo_wen),
    .raw_payload     (raw_payload),
    .valid_pkt_cnt   (valid_pkt_cnt),
    .invalid_pkt_cnt (invalid_pkt_cnt)
);

`ifdef COCOTB_SIM
initial begin
  $dumpfile("eth_parser.vcd");
  $dumpvars(0, eth_parser);
end
`endif

endmodule
