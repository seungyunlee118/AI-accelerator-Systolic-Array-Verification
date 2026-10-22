// DMA read engine (spec §6.1 Reads).
//
// Fetches one matrix (rows x row_len bytes, row-major with a stride) into the A or B buffer.
// - Each row is one INCR burst of 8-byte beats, split in two if it would cross a 4 KB page.
// - Up to MAX_OT bursts are in flight, each with its own ARID (0..MAX_OT-1). An ID is
//   reserved when its AR is loaded and freed when that burst's RLAST is received.
// - R data may come back out of order and interleaved across IDs. A per-ID table records
//   which buffer row and beat the next returning beat of that burst belongs to.
// - On an RRESP error no new AR is loaded; bursts already in flight are drained, then
//   done is pulsed with err = 1.
module sa_dma_rd #(
  parameter int MAX_OT = 4
)(
  input  logic        clk,
  input  logic        rst_n,

  // command from the controller (accepted when cmd_ready)
  input  logic        cmd_valid,
  output logic        cmd_ready,
  input  logic [31:0] cmd_base,
  input  logic [15:0] cmd_stride,
  input  logic [6:0]  cmd_rows,      // 1..64
  input  logic [6:0]  cmd_row_len,   // bytes per row, 1..64
  input  logic        cmd_sel,       // 0: A buffer, 1: B buffer
  output logic        done,          // one-cycle pulse: every burst has completed
  output logic        err,           // valid with done: some RRESP was not OKAY

  // buffer write port: one 8-byte beat per cycle
  output logic        buf_we,
  output logic        buf_sel,
  output logic [5:0]  buf_row,
  output logic [2:0]  buf_beat,
  output logic [63:0] buf_data,

  // AXI4 read address / read data channels
  output logic [3:0]  m_axi_arid,
  output logic [31:0] m_axi_araddr,
  output logic [7:0]  m_axi_arlen,
  output logic [2:0]  m_axi_arsize,
  output logic [1:0]  m_axi_arburst,
  output logic        m_axi_arvalid,
  input  logic        m_axi_arready,
  input  logic [3:0]  m_axi_rid,
  input  logic [63:0] m_axi_rdata,
  input  logic [1:0]  m_axi_rresp,
  input  logic        m_axi_rlast,
  input  logic        m_axi_rvalid,
  output logic        m_axi_rready
);
  localparam int IDW = $clog2(MAX_OT);

  typedef enum logic [1:0] {S_IDLE, S_ISSUE, S_DRAIN} state_t;
  state_t state;

  // latched command
  logic [15:0] stride_q;
  logic [6:0]  rows_q, row_len_q;
  logic        sel_q;

  // burst generator
  logic [6:0]  row;          // row being issued
  logic [31:0] row_addr;     // byte address of that row
  logic        seg;          // 0: first (or only) burst of the row, 1: second burst after a split
  logic [3:0]  first_beats;  // beats in the first burst of a split row

  // per-ID table
  logic [MAX_OT-1:0] inflight;
  logic [5:0]        tab_row  [MAX_OT];
  logic [2:0]        tab_beat [MAX_OT];   // buffer beat the next returning beat goes to
  logic              err_seen;

  // ------------------------------------------------------------ current burst (combinational)
  logic [3:0]  beats_total;   // beats per row, 1..8
  logic [9:0]  beats_room;    // beats left before the next 4 KB boundary, 1..512
  logic [3:0]  burst_beats;
  logic [31:0] burst_addr;
  logic [2:0]  burst_beat0;
  logic        split_row;
  logic        last_burst;

  always_comb begin
    beats_total = 4'((8'(row_len_q) + 8'd7) >> 3);
    if (!seg) begin
      burst_addr  = row_addr;
      burst_beat0 = 3'd0;
      beats_room  = 10'((13'h1000 - {1'b0, row_addr[11:0]}) >> 3);
      burst_beats = (beats_room < 10'(beats_total)) ? beats_room[3:0] : beats_total;
    end else begin
      burst_addr  = row_addr + 32'({first_beats, 3'b000});
      burst_beat0 = first_beats[2:0];
      beats_room  = '0;
      burst_beats = beats_total - first_beats;
    end
    split_row  = !seg && (burst_beats < beats_total);
    last_burst = !split_row && (row == rows_q - 7'd1);
  end

  // ------------------------------------------------------------ lowest free ID
  logic           id_free;
  logic [IDW-1:0] free_id;

  always_comb begin
    id_free = 1'b0;
    free_id = '0;
    for (int i = MAX_OT - 1; i >= 0; i--)
      if (!inflight[i]) begin
        id_free = 1'b1;
        free_id = IDW'(i);
      end
  end

  // ------------------------------------------------------------ R beat
  logic [IDW-1:0] r_id;
  logic           r_hit;    // accepted beat of a burst we are waiting for
  logic           r_err;

  assign r_id  = m_axi_rid[IDW-1:0];
  assign r_hit = m_axi_rvalid && m_axi_rready && (m_axi_rid < MAX_OT) && inflight[r_id];
  assign r_err = r_hit && (m_axi_rresp != 2'b00);

  // Load a new AR only when the AR register is empty, an ID is free, and no error has been
  // seen (including one arriving this very cycle).
  logic load_ar;
  assign load_ar = (state == S_ISSUE) && !err_seen && !r_err && !m_axi_arvalid && id_free;

  // ------------------------------------------------------------ sequential
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state         <= S_IDLE;
      stride_q      <= '0;
      rows_q        <= '0;
      row_len_q     <= '0;
      sel_q         <= 1'b0;
      row           <= '0;
      row_addr      <= '0;
      seg           <= 1'b0;
      first_beats   <= '0;
      inflight      <= '0;
      err_seen      <= 1'b0;
      m_axi_arvalid <= 1'b0;
      m_axi_arid    <= '0;
      m_axi_araddr  <= '0;
      m_axi_arlen   <= '0;
      done          <= 1'b0;
      err           <= 1'b0;
      for (int i = 0; i < MAX_OT; i++) begin
        tab_row[i]  <= '0;
        tab_beat[i] <= '0;
      end
    end else begin
      done <= 1'b0;

      if (m_axi_arvalid && m_axi_arready)
        m_axi_arvalid <= 1'b0;

      // returning beat: advance that burst's write position; RLAST frees its ID
      if (r_hit) begin
        tab_beat[r_id] <= tab_beat[r_id] + 3'd1;
        if (m_axi_rlast) inflight[r_id] <= 1'b0;
        if (r_err)       err_seen       <= 1'b1;
      end

      case (state)
        S_IDLE: begin
          if (cmd_valid) begin
            stride_q  <= cmd_stride;
            rows_q    <= cmd_rows;
            row_len_q <= cmd_row_len;
            sel_q     <= cmd_sel;
            row       <= '0;
            row_addr  <= cmd_base;
            seg       <= 1'b0;
            err_seen  <= 1'b0;
            err       <= 1'b0;
            state     <= S_ISSUE;
          end
        end

        S_ISSUE: begin
          if (err_seen || r_err) begin
            state <= S_DRAIN;
          end else if (load_ar) begin
            // free_id is not in flight, so it cannot collide with r_id above
            m_axi_arvalid     <= 1'b1;
            m_axi_arid        <= 4'(free_id);
            m_axi_araddr      <= burst_addr;
            m_axi_arlen       <= 8'(burst_beats - 4'd1);
            inflight[free_id] <= 1'b1;
            tab_row[free_id]  <= row[5:0];
            tab_beat[free_id] <= burst_beat0;
            if (split_row) begin
              seg         <= 1'b1;
              first_beats <= burst_beats;
            end else begin
              seg      <= 1'b0;
              row      <= row + 7'd1;
              row_addr <= row_addr + 32'(stride_q);
              if (last_burst) state <= S_DRAIN;
            end
          end
        end

        S_DRAIN: begin
          if (!m_axi_arvalid && inflight == '0) begin
            done  <= 1'b1;
            err   <= err_seen;
            state <= S_IDLE;
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

  // ------------------------------------------------------------ outputs
  assign cmd_ready     = (state == S_IDLE);
  assign m_axi_arsize  = 3'd3;       // 8 bytes per beat
  assign m_axi_arburst = 2'b01;      // INCR
  assign m_axi_rready  = 1'b1;       // the buffer takes one beat every cycle

  assign buf_we   = r_hit;
  assign buf_sel  = sel_q;
  assign buf_row  = tab_row[r_id];
  assign buf_beat = tab_beat[r_id];
  assign buf_data = m_axi_rdata;
endmodule
