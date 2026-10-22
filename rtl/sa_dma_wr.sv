// DMA write engine (spec §6.1 Writes).
//
// Writes one contiguous run of bytes (one row segment of C) to memory:
// - 8-byte beats, INCR, AWID 0, at most one burst outstanding;
// - WSTRB enables exactly the bytes of the run, nothing else;
// - a run that would cross a 4 KB boundary is split into two bursts;
// - each burst's AW is accepted before its first W beat, so AWVALID never trails WVALID.
// On a BRESP error no further burst is issued, and done is pulsed with err = 1.
module sa_dma_wr #(
  parameter int MAX_BYTES = 16              // longest run: 4 bytes x ARRAY_N (INT32 row)
)(
  input  logic                   clk,
  input  logic                   rst_n,

  // command from the controller (accepted when cmd_ready)
  input  logic                   cmd_valid,
  output logic                   cmd_ready,
  input  logic [31:0]            cmd_addr,     // byte address of the first byte of the run
  input  logic [5:0]             cmd_nbytes,   // 1..MAX_BYTES
  input  logic [8*MAX_BYTES-1:0] cmd_data,     // byte 0 = first byte of the run
  output logic                   done,         // one-cycle pulse when the run is finished
  output logic                   err,          // valid with done: some BRESP was not OKAY

  // AXI4 write channels
  output logic [3:0]             m_axi_awid,
  output logic [31:0]            m_axi_awaddr,
  output logic [7:0]             m_axi_awlen,
  output logic [2:0]             m_axi_awsize,
  output logic [1:0]             m_axi_awburst,
  output logic                   m_axi_awvalid,
  input  logic                   m_axi_awready,
  output logic [63:0]            m_axi_wdata,
  output logic [7:0]             m_axi_wstrb,
  output logic                   m_axi_wlast,
  output logic                   m_axi_wvalid,
  input  logic                   m_axi_wready,
  input  logic [3:0]             m_axi_bid,
  input  logic [1:0]             m_axi_bresp,
  input  logic                   m_axi_bvalid,
  output logic                   m_axi_bready
);
  localparam int SPAN_BYTES = MAX_BYTES + 8;        // room for a start offset of 0..7 bytes
  localparam int SPAN_BITS  = 8 * SPAN_BYTES;

  typedef enum logic [1:0] {S_IDLE, S_AW, S_W, S_B} state_t;
  state_t state;

  logic [SPAN_BITS-1:0]  span_data;     // the run shifted to its byte lanes, beat 0 first
  logic [SPAN_BYTES-1:0] span_strb;
  logic [31:0]           beat0_addr;    // 8-byte-aligned address of beat 0
  logic [3:0]            total_beats;   // beats in the whole run
  logic [3:0]            burst_first;   // index of the current burst's first beat
  logic [3:0]            beat;          // beats sent so far in the current burst

  // ------------------------------------------------------------ current burst
  logic [31:0] burst_addr;
  logic [9:0]  beats_room;              // beats before the next 4 KB boundary
  logic [3:0]  beats_left;
  logic [3:0]  burst_beats;
  logic [3:0]  beat_idx;

  always_comb begin
    burst_addr  = beat0_addr + 32'({burst_first, 3'b000});
    beats_room  = 10'((13'h1000 - {1'b0, burst_addr[11:0]}) >> 3);
    beats_left  = total_beats - burst_first;
    burst_beats = (beats_room < 10'(beats_left)) ? beats_room[3:0] : beats_left;
    beat_idx    = burst_first + beat;
  end

  // ------------------------------------------------------------ sequential
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state       <= S_IDLE;
      span_data   <= '0;
      span_strb   <= '0;
      beat0_addr  <= '0;
      total_beats <= '0;
      burst_first <= '0;
      beat        <= '0;
      done        <= 1'b0;
      err         <= 1'b0;
    end else begin
      done <= 1'b0;
      case (state)
        S_IDLE: begin
          if (cmd_valid) begin
            span_data   <= SPAN_BITS'(cmd_data) << {cmd_addr[2:0], 3'b000};
            span_strb   <= SPAN_BYTES'((64'd1 << cmd_nbytes) - 64'd1) << cmd_addr[2:0];
            beat0_addr  <= {cmd_addr[31:3], 3'b000};
            total_beats <= 4'((7'(cmd_addr[2:0]) + 7'(cmd_nbytes) + 7'd7) >> 3);
            burst_first <= '0;
            err         <= 1'b0;
            state       <= S_AW;
          end
        end

        S_AW: begin
          if (m_axi_awready) begin
            beat  <= '0;
            state <= S_W;
          end
        end

        S_W: begin
          if (m_axi_wready) begin
            if (beat == burst_beats - 4'd1) state <= S_B;
            else                            beat  <= beat + 4'd1;
          end
        end

        S_B: begin
          if (m_axi_bvalid) begin
            if (m_axi_bresp != 2'b00) begin            // error: no more bursts
              done  <= 1'b1;
              err   <= 1'b1;
              state <= S_IDLE;
            end else if (burst_first + burst_beats < total_beats) begin
              burst_first <= burst_first + burst_beats;  // second half of a split run
              state       <= S_AW;
            end else begin
              done  <= 1'b1;
              state <= S_IDLE;
            end
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

  // ------------------------------------------------------------ outputs
  assign cmd_ready     = (state == S_IDLE);

  assign m_axi_awid    = 4'd0;
  assign m_axi_awaddr  = burst_addr;
  assign m_axi_awlen   = 8'(burst_beats - 4'd1);
  assign m_axi_awsize  = 3'd3;          // 8 bytes per beat
  assign m_axi_awburst = 2'b01;         // INCR
  assign m_axi_awvalid = (state == S_AW);

  assign m_axi_wvalid  = (state == S_W);
  assign m_axi_wdata   = span_data[64*beat_idx +: 64];
  assign m_axi_wstrb   = span_strb[8*beat_idx +: 8];
  assign m_axi_wlast   = (state == S_W) && (beat == burst_beats - 4'd1);

  assign m_axi_bready  = (state == S_B);
endmodule
