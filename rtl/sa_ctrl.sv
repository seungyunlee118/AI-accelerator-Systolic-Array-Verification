// Controller (spec §6): configuration check, A/B loads, tiled compute, C write-back.
//
//   IDLE --START--> CHECK --bad config--> IDLE (ERR, BUSY never set)
//                     |
//                     v
//   RD_A -> RD_A_WAIT -> RD_B -> RD_B_WAIT -> [ CLEAR -> FEED -> WR -> WR_WAIT ... ] per tile -> IDLE (DONE)
//                                            any DMA error ---------------------------------> IDLE (ERR)
//
// Tiles are ARRAY_N x ARRAY_N output blocks, row-major (tile row outer, tile column inner).
// For each tile the array is cleared, fed for K + 2*ARRAY_N - 2 cycles with skewed A rows and
// B columns (zeros outside the matrix), and then each valid row of the tile goes through the
// output stage and is written as one run of bytes.
module sa_ctrl #(
  parameter int AN      = 4,       // ARRAY_N
  parameter int MAX_DIM = 64
)(
  input  logic               clk,
  input  logic               rst_n,

  // from the CSR block
  input  logic               start,
  input  logic [6:0]         dim_m,
  input  logic [6:0]         dim_n,
  input  logic [6:0]         dim_k,
  input  logic [31:0]        a_base,
  input  logic [15:0]        a_stride,
  input  logic [31:0]        b_base,
  input  logic [15:0]        b_stride,
  input  logic [31:0]        c_base,
  input  logic [15:0]        c_stride,
  input  logic               req_en,
  input  logic               relu_en,
  input  logic [4:0]         shift,
  input  logic [15:0]        scale,

  // to the CSR block
  output logic               busy,
  output logic [3:0]         err_code,
  output logic               evt_done,
  output logic               evt_err,
  output logic [31:0]        cycles,

  // DMA read engine
  output logic               rd_cmd_valid,
  input  logic               rd_cmd_ready,
  output logic [31:0]        rd_cmd_base,
  output logic [15:0]        rd_cmd_stride,
  output logic [6:0]         rd_cmd_rows,
  output logic [6:0]         rd_cmd_row_len,
  output logic               rd_cmd_sel,
  input  logic               rd_done,
  input  logic               rd_err,
  input  logic               buf_we,
  input  logic               buf_sel,
  input  logic [5:0]         buf_row,
  input  logic [2:0]         buf_beat,
  input  logic [63:0]        buf_data,

  // DMA write engine
  output logic               wr_cmd_valid,
  input  logic               wr_cmd_ready,
  output logic [31:0]        wr_cmd_addr,
  output logic [5:0]         wr_cmd_nbytes,
  output logic [32*AN-1:0]   wr_cmd_data,
  input  logic               wr_done,
  input  logic               wr_err
);
  typedef enum logic [3:0] {
    S_IDLE, S_CHECK, S_RD_A, S_RD_A_WAIT, S_RD_B, S_RD_B_WAIT,
    S_CLEAR, S_FEED, S_WR, S_WR_WAIT, S_NEXT_TILE
  } state_t;
  state_t state;

  // configuration sampled at START (spec §4: later CSR writes do not affect the job)
  logic [6:0]  m_q, n_q, k_q;
  logic [31:0] a_base_q, b_base_q, c_base_q;
  logic [15:0] a_str_q, b_str_q, c_str_q;
  logic        req_q, relu_q;
  logic [4:0]  shift_q;
  logic [15:0] scale_q;

  // tile position and progress
  logic [6:0]  ti, tj;          // first row / column of the current tile
  logic [7:0]  t;               // feed step
  logic [3:0]  wr_row;          // tile row being written
  logic [31:0] cyc_cnt;

  // results reported to the CSR block
  logic [3:0]  err_code_q;
  logic [31:0] cycles_q;

  // ------------------------------------------------------------ A/B buffers (64 x 64 bytes each)
  logic [7:0] a_buf [MAX_DIM][MAX_DIM];
  logic [7:0] b_buf [MAX_DIM][MAX_DIM];

  always_ff @(posedge clk) begin
    if (buf_we) begin
      for (int b = 0; b < 8; b++) begin
        if (!buf_sel) a_buf[buf_row][{buf_beat, 3'(b)}] <= buf_data[8*b +: 8];
        else          b_buf[buf_row][{buf_beat, 3'(b)}] <= buf_data[8*b +: 8];
      end
    end
  end

  // ------------------------------------------------------------ configuration check
  logic        bad_dim, bad_addr;
  logic [8:0]  c_min_stride;    // E * N bytes

  always_comb begin
    bad_dim = (m_q == 0) || (m_q > MAX_DIM) || (n_q == 0) || (n_q > MAX_DIM) ||
              (k_q == 0) || (k_q > MAX_DIM);
    c_min_stride = req_q ? 9'(n_q) : 9'({n_q, 2'b00});
    bad_addr = (a_base_q[2:0] != 0) || (b_base_q[2:0] != 0) || (c_base_q[2:0] != 0) ||
               (a_str_q[2:0]  != 0) || (b_str_q[2:0]  != 0) || (c_str_q[2:0]  != 0) ||
               (c_str_q < 16'(c_min_stride));
  end

  // ------------------------------------------------------------ PE array and its feeding
  logic signed [7:0]  a_west  [AN];
  logic signed [7:0]  b_north [AN];
  logic signed [31:0] c_out   [AN][AN];
  logic [7:0]         feed_last;    // last feed step: K + 2*AN - 3

  assign feed_last = 8'(k_q) + 8'(2 * AN - 3);

  always_comb begin
    int ki;
    for (int i = 0; i < AN; i++) begin
      ki = int'(t) - i;                         // row i is delayed by i steps
      a_west[i] = '0;
      if (state == S_FEED && int'(ti) + i < int'(m_q) && ki >= 0 && ki < int'(k_q))
        a_west[i] = a_buf[int'(ti) + i][ki];
    end
    for (int j = 0; j < AN; j++) begin
      ki = int'(t) - j;                         // column j is delayed by j steps
      b_north[j] = '0;
      if (state == S_FEED && int'(tj) + j < int'(n_q) && ki >= 0 && ki < int'(k_q))
        b_north[j] = b_buf[ki][int'(tj) + j];
    end
  end

  sa_array #(.N(AN)) u_array (
    .clk     (clk),
    .rst_n   (rst_n),
    .clear   (state == S_CLEAR),
    .en      (state == S_FEED),
    .a_west  (a_west),
    .b_north (b_north),
    .c_out   (c_out)
  );

  // ------------------------------------------------------------ output stage for the row being written
  logic [31:0] o32 [AN];
  logic [7:0]  o8  [AN];

  for (genvar j = 0; j < AN; j++) begin : g_outq
    sa_outq u_outq (
      .acc     (c_out[wr_row[$clog2(AN)-1:0]][j]),
      .req_en  (req_q),
      .relu_en (relu_q),
      .shift   (shift_q),
      .scale   (scale_q),
      .out32   (o32[j]),
      .out8    (o8[j])
    );
  end

  // ------------------------------------------------------------ write command for one tile row
  logic [6:0] wr_count;     // valid elements in this tile row
  logic       wr_row_ok;    // this tile row is inside the matrix

  always_comb begin
    wr_count  = ((n_q - tj) < 7'(AN)) ? (n_q - tj) : 7'(AN);
    wr_row_ok = (wr_row < 4'(AN)) && (7'(ti) + 7'(wr_row) < m_q);

    wr_cmd_addr   = c_base_q + 32'(7'(ti) + 7'(wr_row)) * 32'(c_str_q) +
                    (req_q ? 32'(tj) : 32'({tj, 2'b00}));
    wr_cmd_nbytes = req_q ? 6'(wr_count) : 6'({wr_count, 2'b00});
    wr_cmd_data   = '0;
    for (int j = 0; j < AN; j++) begin
      if (req_q) wr_cmd_data[8*j  +: 8]  = o8[j];
      else       wr_cmd_data[32*j +: 32] = o32[j];
    end
  end

  assign wr_cmd_valid = (state == S_WR) && wr_row_ok;

  // ------------------------------------------------------------ read commands
  assign rd_cmd_valid   = (state == S_RD_A) || (state == S_RD_B);
  assign rd_cmd_sel     = (state == S_RD_B);
  assign rd_cmd_base    = (state == S_RD_B) ? b_base_q : a_base_q;
  assign rd_cmd_stride  = (state == S_RD_B) ? b_str_q  : a_str_q;
  assign rd_cmd_rows    = (state == S_RD_B) ? k_q      : m_q;
  assign rd_cmd_row_len = (state == S_RD_B) ? n_q      : k_q;

  // ------------------------------------------------------------ state machine
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state      <= S_IDLE;
      m_q <= '0;  n_q <= '0;  k_q <= '0;
      a_base_q <= '0;  b_base_q <= '0;  c_base_q <= '0;
      a_str_q  <= '0;  b_str_q  <= '0;  c_str_q  <= '0;
      req_q <= 1'b0;  relu_q <= 1'b0;  shift_q <= '0;  scale_q <= '0;
      ti <= '0;  tj <= '0;  t <= '0;  wr_row <= '0;
      cyc_cnt    <= '0;
      err_code_q <= '0;
      cycles_q   <= '0;
      evt_done   <= 1'b0;
      evt_err    <= 1'b0;
    end else begin
      evt_done <= 1'b0;
      evt_err  <= 1'b0;
      if (busy) cyc_cnt <= cyc_cnt + 32'd1;

      case (state)
        S_IDLE: begin
          if (start) begin
            m_q <= dim_m;  n_q <= dim_n;  k_q <= dim_k;
            a_base_q <= a_base;  b_base_q <= b_base;  c_base_q <= c_base;
            a_str_q  <= a_stride;  b_str_q <= b_stride;  c_str_q <= c_stride;
            req_q <= req_en;  relu_q <= relu_en;  shift_q <= shift;  scale_q <= scale;
            state <= S_CHECK;
          end
        end

        S_CHECK: begin
          if (bad_dim || bad_addr) begin            // configuration error: BUSY is never set
            err_code_q <= bad_dim ? 4'd1 : 4'd2;
            cycles_q   <= '0;
            evt_err    <= 1'b1;
            state      <= S_IDLE;
          end else begin
            cyc_cnt <= '0;
            state   <= S_RD_A;
          end
        end

        S_RD_A:      if (rd_cmd_ready) state <= S_RD_A_WAIT;
        S_RD_A_WAIT: if (rd_done) begin
                       if (rd_err) finish(4'd3);
                       else        state <= S_RD_B;
                     end
        S_RD_B:      if (rd_cmd_ready) state <= S_RD_B_WAIT;
        S_RD_B_WAIT: if (rd_done) begin
                       if (rd_err) finish(4'd3);
                       else begin
                         ti    <= '0;
                         tj    <= '0;
                         state <= S_CLEAR;
                       end
                     end

        S_CLEAR: begin
          t     <= '0;
          state <= S_FEED;
        end

        S_FEED: begin
          if (t == feed_last) begin
            wr_row <= '0;
            state  <= S_WR;
          end else begin
            t <= t + 8'd1;
          end
        end

        S_WR: begin
          if (!wr_row_ok)        state <= S_NEXT_TILE;   // rows below M are padding
          else if (wr_cmd_ready) state <= S_WR_WAIT;
        end

        S_WR_WAIT: if (wr_done) begin
                     if (wr_err) finish(4'd4);
                     else begin
                       wr_row <= wr_row + 4'd1;
                       state  <= S_WR;
                     end
                   end

        S_NEXT_TILE: begin
          if (7'(tj) + 7'(AN) < n_q) begin
            tj    <= tj + 7'(AN);
            state <= S_CLEAR;
          end else if (7'(ti) + 7'(AN) < m_q) begin
            tj    <= '0;
            ti    <= ti + 7'(AN);
            state <= S_CLEAR;
          end else begin
            finish(4'd0);
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

  // End a job that got past the configuration check (code 0 = success).
  task automatic finish(input logic [3:0] code);
    err_code_q <= code;
    cycles_q   <= cyc_cnt + 32'd1;      // include this last busy cycle
    evt_done   <= (code == 4'd0);
    evt_err    <= (code != 4'd0);
    state      <= S_IDLE;
  endtask

  assign busy     = (state != S_IDLE) && (state != S_CHECK);
  assign err_code = err_code_q;
  assign cycles   = cycles_q;
endmodule
