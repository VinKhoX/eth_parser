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

// ---------------------------------------------------------------------------
// FSM states
// ---------------------------------------------------------------------------
localparam [2:0]
    S_IDLE   = 3'd0,
    S_HEADER = 3'd1,
    S_ETYPE  = 3'd2,
    S_VLAN   = 3'd3,
    S_DATA   = 3'd4,
    S_CRC    = 3'd5,
    S_REPLAY = 3'd6,
    S_DROP   = 3'd7;

// ---------------------------------------------------------------------------
// Input pipeline (SOP/EOP detection)
// ---------------------------------------------------------------------------
reg rx_valid_d1;
always @(posedge clk) rx_valid_d1 <= rst ? 1'b0 : rx_valid;

wire sop_wire = rx_valid  & ~rx_valid_d1;
wire eop_wire = ~rx_valid &  rx_valid_d1;

assign crc_init = sop_wire;   // combinational – crc32 resets at SOP edge

// ---------------------------------------------------------------------------
// Internal registers
// ---------------------------------------------------------------------------
reg [2:0]  fsm_state;
reg [4:0]  byte_cnt;
reg [4:0]  data_byte_cnt;   // saturates at 4 in S_DATA

// EtherType parsing
reg [7:0]  etype_hi;

// VLAN
reg [11:0] vlan_id;          // 12-bit 802.1Q VID
reg [7:0]  tci_byte0;        // holds first TCI byte until second arrives

// Error / replay control
reg        pkt_err_latch;
reg [31:0] rx_crc_captured;

// CRC-strip trailing window (holds last 4 S_DATA bytes = FCS)
reg [7:0]  trail_buf [0:3];

// Payload buffer
reg [7:0]  pkt_buf [0:MAX_PKT-1];
reg [10:0] buf_wr_ptr;
reg [10:0] buf_rd_ptr;

// ---------------------------------------------------------------------------
// FSM
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst) begin
        fsm_state       <= S_IDLE;
        byte_cnt        <= 5'd0;
        data_byte_cnt   <= 5'd0;
        etype_hi        <= 8'd0;
        vlan_id         <= 12'd0;
        tci_byte0       <= 8'd0;
        pkt_err_latch   <= 1'b0;
        rx_crc_captured <= 32'd0;
        buf_wr_ptr      <= 11'd0;
        buf_rd_ptr      <= 11'd0;
        trail_buf[0]    <= 8'd0;  trail_buf[1] <= 8'd0;
        trail_buf[2]    <= 8'd0;  trail_buf[3] <= 8'd0;
        fifo_wen        <= 2'b00;
        raw_payload     <= 8'd0;
        crc_data        <= 8'd0;
        crc_vld         <= 1'b0;
        crc_err_cnt     <= 16'd0;
        pkt_err_cnt     <= 16'd0;
        vlan_err_cnt    <= 16'd0;
        valid_pkt_cnt   <= 16'd0;
    end else begin
        // Default: suppress outputs
        fifo_wen    <= 2'b00;
        raw_payload <= 8'd0;
        crc_vld     <= 1'b0;
        crc_data    <= 8'd0;

        if (rx_valid && rx_err)
            pkt_err_latch <= 1'b1;

        case (fsm_state)

            // ----------------------------------------------------------------
            S_IDLE: begin
                byte_cnt      <= 5'd0;
                data_byte_cnt <= 5'd0;
                buf_wr_ptr    <= 11'd0;
                vlan_id       <= 12'd0;
                pkt_err_latch <= 1'b0;
                if (sop_wire) begin
                    // DA[0] – feed to CRC next cycle (registered outputs)
                    crc_data  <= rx_data;
                    crc_vld   <= 1'b1;
                    byte_cnt  <= 5'd1;
                    fsm_state <= S_HEADER;
                end
            end

            // ----------------------------------------------------------------
            // S_HEADER : bytes 1–11 of DA+SA (byte 0 consumed in S_IDLE)
            // ----------------------------------------------------------------
            S_HEADER: begin
                if (eop_wire) begin
                    pkt_err_cnt <= pkt_err_cnt + 1'b1;
                    fsm_state   <= S_IDLE;
                end else if (rx_valid) begin
                    crc_data  <= rx_data;
                    crc_vld   <= 1'b1;
                    byte_cnt  <= byte_cnt + 1'b1;
                    if (byte_cnt == 5'd11) begin
                        fsm_state <= S_ETYPE;
                        byte_cnt  <= 5'd0;
                    end
                end
            end

            // ----------------------------------------------------------------
            // S_ETYPE : 2-byte EtherType / TPID
            // ----------------------------------------------------------------
            S_ETYPE: begin
                if (eop_wire) begin
                    pkt_err_cnt <= pkt_err_cnt + 1'b1;
                    fsm_state   <= S_IDLE;
                end else if (rx_valid) begin
                    crc_data <= rx_data;
                    crc_vld  <= 1'b1;
                    if (byte_cnt == 5'd0) begin
                        etype_hi <= rx_data;
                        byte_cnt <= 5'd1;
                    end else begin
                        byte_cnt <= 5'd0;
                        if (etype_hi == 8'h81 && rx_data == 8'h00)
                            fsm_state <= S_VLAN;       // 802.1Q tag detected
                        else begin
                            crc_vld   <= 1'b0;
                            fsm_state <= S_DROP;        // non-VLAN → drop
                        end
                    end
                end
            end

            // ----------------------------------------------------------------
            // S_VLAN : 4-byte 802.1Q tag (TCI[2B] + inner-EType[2B])
            //   byte 0 → tci_byte0  (PCP/DEI/VID[11:8])
            //   byte 1 → VID[7:0]   → full VID captured
            //   bytes 2-3 → inner EtherType (fed to CRC, ignored for demux)
            // ----------------------------------------------------------------
            S_VLAN: begin
                if (eop_wire) begin
                    vlan_err_cnt <= vlan_err_cnt + 1'b1;
                    pkt_err_cnt  <= pkt_err_cnt  + 1'b1;
                    fsm_state    <= S_IDLE;
                end else if (rx_valid) begin
                    crc_data  <= rx_data;
                    crc_vld   <= 1'b1;
                    byte_cnt  <= byte_cnt + 1'b1;

                    case (byte_cnt)
                        5'd0: tci_byte0 <= rx_data;
                        5'd1: vlan_id   <= {tci_byte0[3:0], rx_data};
                        default: ;
                    endcase

                    if (byte_cnt == 5'd3) begin
                        byte_cnt <= 5'd0;
                        // Only forward VID 0 or 1; drop everything else
                        if (vlan_id[11:1] == 11'd0)
                            fsm_state <= S_DATA;
                        else begin
                            crc_vld   <= 1'b0;
                            fsm_state <= S_DROP;
                        end
                    end
                end
            end

            // ----------------------------------------------------------------
            // S_DATA : payload + 4-byte FCS trailing window
            //   confirmed payload bytes → pkt_buf + crc feed
            // ----------------------------------------------------------------
            S_DATA: begin
                if (rx_valid) begin
                    trail_buf[0] <= trail_buf[1];
                    trail_buf[1] <= trail_buf[2];
                    trail_buf[2] <= trail_buf[3];
                    trail_buf[3] <= rx_data;

                    if (data_byte_cnt < 5'd4)
                        data_byte_cnt <= data_byte_cnt + 1'b1;

                    if (data_byte_cnt >= 5'd4) begin
                        // trail_buf[0] is a confirmed payload byte
                        crc_data  <= trail_buf[0];
                        crc_vld   <= 1'b1;
                        if (buf_wr_ptr < MAX_PKT) begin
                            pkt_buf[buf_wr_ptr] <= trail_buf[0];
                            buf_wr_ptr          <= buf_wr_ptr + 1'b1;
                        end
                    end
                end

                if (eop_wire) begin
                    // trail_buf holds the received FCS; capture it
                    rx_crc_captured <= {trail_buf[0], trail_buf[1],
                                        trail_buf[2], trail_buf[3]};
                    data_byte_cnt   <= 5'd0;
                    fsm_state       <= S_CRC;
                end
            end

            // ----------------------------------------------------------------
            // S_CRC : validate FCS. If good → S_REPLAY, else → S_IDLE.
            // ----------------------------------------------------------------
            S_CRC: begin
                if (pkt_err_latch) begin
                    pkt_err_cnt   <= pkt_err_cnt + 1'b1;
                    pkt_err_latch <= 1'b0;
                    fsm_state     <= S_IDLE;
                end else if (rx_crc_captured != crc_computed) begin
                    crc_err_cnt <= crc_err_cnt + 1'b1;
                    fsm_state   <= S_IDLE;
                end else begin
                    valid_pkt_cnt <= valid_pkt_cnt + 1'b1;
                    buf_rd_ptr    <= 11'd0;
                    fsm_state     <= S_REPLAY;
                end
            end

            // ----------------------------------------------------------------
            // S_REPLAY : stream pkt_buf to the correct VLAN FIFO port.
            // ----------------------------------------------------------------
            S_REPLAY: begin
                if (buf_rd_ptr < buf_wr_ptr) begin
                    raw_payload           <= pkt_buf[buf_rd_ptr];
                    fifo_wen[vlan_id[0]]  <= 1'b1;
                    buf_rd_ptr            <= buf_rd_ptr + 1'b1;
                end else begin
                    // All bytes replayed – return to idle
                    fifo_wen  <= 2'b00;
                    fsm_state <= S_IDLE;
                end
            end

            // ----------------------------------------------------------------
            // S_DROP : consume frame silently until EOP (no CRC feed)
            // ----------------------------------------------------------------
            S_DROP: begin
                if (eop_wire)
                    fsm_state <= S_IDLE;
            end

            default: fsm_state <= S_IDLE;

        endcase
    end
end

endmodule

