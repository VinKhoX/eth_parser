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

    localparam [2:0] S_IDLE   = 3'd0,
                     S_RECV   = 3'd1,
                     S_REPLAY = 3'd2,
                     S_DROP   = 3'd3;

    reg [2:0]  state, next_state;
    reg        rx_valid_d1;
    wire       sop = rx_valid & ~rx_valid_d1;
    wire       eop = ~rx_valid & rx_valid_d1;

    wire       is_valid_eop = (tpid == 16'h8100) & (vlan_id <= 12'd1) & (byte_cnt >= 12'd22) & ~err_latch;
    wire       is_silent_drop = (tpid == 16'h8100) & (vlan_id > 12'd1) & (byte_cnt >= 12'd22) & ~err_latch;

    reg [11:0] byte_cnt;       // byte index in frame
    reg [15:0] tpid;
    reg [11:0] vlan_id;
    reg        err_latch;      // rx_err seen this frame
    reg        silent_drop;    // drop due to VID>1 only; do not increment invalid
    reg        is_valid;       // 1 = accept (VLAN 0/1, long enough), 0 = invalid

    reg [7:0]  pkt_buf [0:MAX_PKT-1];
    reg [11:0] buf_wr_ptr, buf_rd_ptr, payload_len;
    localparam PAYLOAD_START = 12'd18;   // first payload byte index

    always @(posedge clk) rx_valid_d1 <= rst ? 1'b0 : rx_valid;

    // FSM next state
    always @(*) begin
        next_state = state;
        case (state)
            S_IDLE:   if (sop) next_state = S_RECV;
            S_RECV:   if (eop) next_state = is_valid_eop ? S_REPLAY : S_DROP;
            S_REPLAY: if (buf_rd_ptr >= payload_len) next_state = S_IDLE;
            S_DROP:   next_state = S_IDLE;
            default:  next_state = S_IDLE;
        endcase
    end

    always @(posedge clk) begin
        if (rst) begin
            state           <= S_IDLE;
            byte_cnt        <= 12'd0;
            tpid            <= 16'd0;
            vlan_id         <= 12'd0;
            err_latch       <= 1'b0;
            silent_drop     <= 1'b0;
            is_valid        <= 1'b0;
            buf_wr_ptr      <= 12'd0;
            buf_rd_ptr      <= 12'd0;
            payload_len     <= 12'd0;
            fifo_wen        <= 2'b00;
            raw_payload     <= 8'd0;
            valid_pkt_cnt   <= 16'd0;
            invalid_pkt_cnt <= 16'd0;
        end else begin
            state <= next_state;
            fifo_wen <= 2'b00;

            if (rx_valid & rx_err)
                err_latch <= 1'b1;

            case (state)
                S_IDLE: begin
                    byte_cnt   <= 12'd0;
                    buf_wr_ptr <= 12'd0;
                    err_latch  <= 1'b0;
                    if (sop) begin
                        if (12'd0 < MAX_PKT)
                            pkt_buf[12'd0] <= rx_data;
                        byte_cnt <= 12'd1;
                    end
                end

                S_RECV: begin
                    if (rx_valid) begin
                        if (byte_cnt < MAX_PKT)
                            pkt_buf[byte_cnt] <= rx_data;
                        case (byte_cnt)
                            12'd12: tpid[15:8] <= rx_data;  // TPID byte 0
                            12'd13: tpid[7:0]  <= rx_data;  // TPID byte 1
                            12'd14: ; // TCI high
                            12'd15: vlan_id    <= {4'b0, rx_data}; // VID[7:0]
                            default: ;
                        endcase
                        byte_cnt <= byte_cnt + 1'b1;
                    end
                    if (eop) begin
                        is_valid    <= (tpid == 16'h8100) & (vlan_id <= 12'd1) & (byte_cnt >= 12'd22) & ~err_latch;
                        silent_drop  <= is_silent_drop;
                        payload_len  <= (byte_cnt >= 12'd22) ? (byte_cnt - 12'd22) : 12'd0;
                        buf_rd_ptr   <= 12'd0;
                    end
                end

                S_REPLAY: begin
                    if (buf_rd_ptr < payload_len) begin
                        raw_payload <= pkt_buf[PAYLOAD_START + buf_rd_ptr];
                        if (vlan_id == 12'd0) fifo_wen[0] <= 1'b1;
                        else if (vlan_id == 12'd1) fifo_wen[1] <= 1'b1;
                        buf_rd_ptr  <= buf_rd_ptr + 1'b1;
                    end else
                        valid_pkt_cnt <= valid_pkt_cnt + 1'b1;
                end

                S_DROP: if (!silent_drop) invalid_pkt_cnt <= invalid_pkt_cnt + 1'b1;

                default: ;
            endcase
        end
    end

endmodule
