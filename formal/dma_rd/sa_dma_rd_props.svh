// Formal properties for the DMA read engine (spec §6.1 Reads, §8), proven with SymbiYosys.
// Included into sa_dma_rd when FORMAL is defined (open-source Yosys has no `bind`).
//
// ASSUME (the environment):
//   - reset at the start only;
//   - the controller holds a legal command (1..64 rows of 1..64 bytes, base and stride multiples
//     of 8) stable until it is accepted;
//   - the memory follows AXI4: R beats only for an ID with a burst in flight, beats of one ID in
//     order, RLAST exactly on the burst's last beat. Everything else is free: ARREADY, when and in
//     which order bursts return (any interleaving across IDs), RRESP.
// ASSERT (what the DMA guarantees, for every such environment):
//   P1  AR protocol: ARVALID held until ARREADY with a stable payload; INCR, 8-byte beats,
//       at most 8 beats, 8-byte aligned, never across a 4 KB boundary; ARID 0..3.
//   P2  ID rules: an ARID is never issued while its previous burst is in flight (so at most 4
//       bursts are outstanding), and IDs are only used between command and done.
//   P3  Data placement: every R beat is written to the buffer, into the slot the spec says: the
//       beat's bus address is the spec address of its slot, base + row * stride + 8 * beat, with
//       row < rows and beat < the row's beats, in the commanded buffer (A or B).
//   P4  Errors: after an RRESP error no new burst starts; done comes only when nothing is in
//       flight, with err = whether any beat of this command had an error.
//   P5  Completeness: a command that ends without an error has written every slot of every row
//       (no missing data). The slot is chosen by the solver (anyconst), so this covers all
//       slots, for every size up to 64 x 64.
//
// No multiplication. base + row * stride with both factors free is the worst case for SMT
// solvers (the first version, which used it directly, did not finish in 10+ minutes with yices,
// bitwuzla, boolector or abc pdr). Instead the shadow keeps f_row_base, the spec address of the
// DMA's current row, by adding the stride once per row step, starting from base, and P0 checks
// that the row counter only ever steps by one. So f_row_base = base + row * stride holds by
// construction, and the solver only sees additions and comparisons. At each AR load the shadow
// records which row the DMA claims and that row's spec address; P3 compares beats against them.

  logic f_past_valid = 1'b0;
  always @(posedge clk) f_past_valid <= 1'b1;

  initial assume (!rst_n);
  always @(*) if (f_past_valid) assume (rst_n);

  // ---------------------------------------------------------------- shadow of the command
  logic        f_busy;                 // a command was accepted and done has not come yet
  logic [31:0] f_base;
  logic [15:0] f_stride;
  logic [6:0]  f_rows, f_row_len;
  logic        f_sel, f_err;
  logic [3:0]  f_beats;                // beats per row
  assign f_beats = 4'((8'(f_row_len) + 8'd7) >> 3);

  // spec address of a row, built by addition: f_row_base belongs to row f_row_seen, which
  // follows the DMA's row counter one cycle late; f_cur_base is the spec address of 'row' now
  logic [6:0]  f_row_seen;
  logic [31:0] f_row_base, f_cur_base;
  assign f_cur_base = (row == f_row_seen) ? f_row_base : f_row_base + 32'(f_stride);

  // ---------------------------------------------------------------- shadow of the AXI bus
  logic [MAX_OT-1:0] f_inflight;       // AR accepted, RLAST not yet
  logic [31:0]       f_addr [MAX_OT];  // ARADDR of the burst on each ID
  logic [2:0]        f_len  [MAX_OT];  // ARLEN
  logic [2:0]        f_cnt  [MAX_OT];  // beats already returned
  // recorded when the DMA loads an AR: the row it is for, and that row's spec address
  logic [5:0]        f_id_row  [MAX_OT];
  logic [31:0]       f_id_base [MAX_OT];

  logic [IDW-1:0] f_rid;
  logic [31:0]    f_beat_addr;         // bus address of the R beat on the bus now
  assign f_rid       = m_axi_rid[IDW-1:0];
  assign f_beat_addr = f_addr[f_rid] + {f_cnt[f_rid], 3'b000};

  // ---------------------------------------------------------------- environment
  // the controller: legal command, held stable until accepted
  always @(*)
    if (cmd_valid)
      assume (cmd_rows >= 7'd1 && cmd_rows <= 7'd64 && cmd_row_len >= 7'd1 && cmd_row_len <= 7'd64 &&
              cmd_base[2:0] == 3'b0 && cmd_stride[2:0] == 3'b0);
  always @(posedge clk)
    if (f_past_valid && $past(rst_n) && $past(cmd_valid && !cmd_ready))
      assume (cmd_valid && $stable({cmd_base, cmd_stride, cmd_rows, cmd_row_len, cmd_sel}));

  // the memory: AXI4 read rules
  always @(*)
    if (m_axi_rvalid)
      assume (m_axi_rid < MAX_OT && f_inflight[f_rid] && m_axi_rlast == (f_cnt[f_rid] == f_len[f_rid]));

`ifdef SMALL
  // cover and bmc tasks: small commands, so short traces show each scenario or bug
  always @(*) if (cmd_valid) assume (cmd_rows <= 7'd3 && cmd_row_len <= 7'd24);
`endif

  // ---------------------------------------------------------------- shadow update
  always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      f_busy <= 1'b0;  f_err <= 1'b0;  f_sel <= 1'b0;
      f_base <= '0;  f_stride <= '0;  f_rows <= '0;  f_row_len <= '0;
      f_row_seen <= '0;  f_row_base <= '0;
      f_inflight <= '0;
      for (int i = 0; i < MAX_OT; i++) begin
        f_addr[i] <= '0;  f_len[i] <= '0;  f_cnt[i] <= '0;  f_id_row[i] <= '0;  f_id_base[i] <= '0;
      end
    end else begin
      if (done) f_busy <= 1'b0;
      if (cmd_valid && cmd_ready) begin                    // a new command wins over done
        f_busy <= 1'b1;  f_err <= 1'b0;  f_sel <= cmd_sel;
        f_base <= cmd_base;  f_stride <= cmd_stride;  f_rows <= cmd_rows;  f_row_len <= cmd_row_len;
        f_row_seen <= '0;  f_row_base <= cmd_base;         // row 0 starts at base
      end else if (row != f_row_seen) begin                // the DMA moved to the next row
        f_row_seen <= row;
        f_row_base <= f_cur_base;                          // + stride
      end
      if (load_ar) begin                                   // the DMA loads an AR for 'row'
        f_id_row[free_id]  <= row[5:0];
        f_id_base[free_id] <= f_cur_base;
      end
      if (m_axi_arvalid && m_axi_arready) begin
        f_inflight[m_axi_arid[IDW-1:0]] <= 1'b1;
        f_addr[m_axi_arid[IDW-1:0]]     <= m_axi_araddr;
        f_len[m_axi_arid[IDW-1:0]]      <= m_axi_arlen[2:0];
        f_cnt[m_axi_arid[IDW-1:0]]      <= '0;
      end
      if (m_axi_rvalid && m_axi_rready) begin
        f_cnt[f_rid] <= f_cnt[f_rid] + 3'd1;
        if (m_axi_rlast)          f_inflight[f_rid] <= 1'b0;
        if (m_axi_rresp != 2'b00) f_err <= 1'b1;
      end
    end

  // ---------------------------------------------------------------- assertions
  // P0 the row counter counts 0, 1, 2, ... (what makes f_row_base = base + row * stride)
  always @(*)
    if (rst_n && f_busy && !(cmd_valid && cmd_ready))
      assert (row == f_row_seen || row == f_row_seen + 7'd1);

  // P1 AR protocol and burst shape
  always @(posedge clk)
    if (f_past_valid && $past(rst_n) && rst_n && $past(m_axi_arvalid && !m_axi_arready))
      assert (m_axi_arvalid && $stable({m_axi_arid, m_axi_araddr, m_axi_arlen}));

  always @(*)
    if (rst_n && m_axi_arvalid) begin
      assert (m_axi_arsize == 3'd3 && m_axi_arburst == 2'b01);
      assert (m_axi_arlen <= 8'd7 && m_axi_araddr[2:0] == 3'b0 && m_axi_arid < MAX_OT);
      assert (13'(m_axi_araddr[11:0]) + 13'({m_axi_arlen[3:0], 3'b000}) + 13'd8 <= 13'h1000);
    end

  // P2 ID rules
  always @(*)
    if (rst_n) begin
      if (m_axi_arvalid) assert (!f_inflight[m_axi_arid[IDW-1:0]] && f_busy);
      if (f_inflight != '0) assert (f_busy);
    end

  // P3 every beat lands where the spec says
  always @(*)
    if (rst_n) begin
      assert (m_axi_rready);
      assert (buf_we == m_axi_rvalid);
      if (m_axi_rvalid) begin
        assert (buf_sel == f_sel);
        assert ({1'b0, buf_row} < f_rows && {1'b0, buf_beat} < f_beats);
        assert (buf_row == f_id_row[f_rid] && f_beat_addr == f_id_base[f_rid] + {buf_beat, 3'b000});
      end
    end

  // P4 errors and done
  logic f_ar_wait, f_new_ar;           // new_ar: ARVALID that was not already waiting
  always @(posedge clk or negedge rst_n)
    if (!rst_n) f_ar_wait <= 1'b0;
    else        f_ar_wait <= m_axi_arvalid && !m_axi_arready;
  assign f_new_ar = m_axi_arvalid && !f_ar_wait;
  always @(*)
    if (rst_n) begin
      if (f_err) assert (!f_new_ar);
      if (done)  assert (f_busy && f_inflight == '0 && !m_axi_arvalid && err == f_err);
    end

  // ---------------------------------------------------------------- helper invariants
  // (left out with NO_HELPERS: the bmc_spec task checks that the spec properties alone kill bugs)
`ifndef NO_HELPERS
  // White-box facts that hold in every reachable state. k-induction needs them to rule out
  // unreachable starting states; each one is checked like any other assertion.
  always @(*)
    if (rst_n) begin
      assert (f_busy == (state != S_IDLE || done));      // done is pulsed on the way back to IDLE
      if (f_busy) begin
        // the latched command is the legal one that was accepted
        assert (f_rows >= 7'd1 && f_rows <= 7'd64 && f_row_len >= 7'd1 && f_row_len <= 7'd64);
        assert (f_base[2:0] == 3'b0 && f_stride[2:0] == 3'b0 && f_row_base[2:0] == 3'b0);
        assert (stride_q == f_stride && rows_q == f_rows && row_len_q == f_row_len && sel_q == f_sel);
        assert (err_seen == f_err);
        assert (f_row_seen <= row);
      end
      assert (inflight == (f_inflight | (m_axi_arvalid ? {{(MAX_OT-1){1'b0}}, 1'b1} << m_axi_arid[IDW-1:0] : '0)));
      if (state == S_ISSUE) begin
        assert (row < rows_q);
        assert (row_addr == f_cur_base);
        // a split row's first half ended exactly at the 4 KB boundary
        if (seg) assert (first_beats != 4'd0 && first_beats < f_beats &&
                         13'(row_addr[11:0]) + 13'({first_beats, 3'b000}) == 13'h1000);
      end
    end

  for (genvar i = 0; i < MAX_OT; i++) begin : g_id
    always @(*)
      if (rst_n && inflight[i]) begin
        assert (tab_row[i] == f_id_row[i] && {1'b0, tab_row[i]} < f_rows && f_id_base[i][2:0] == 3'b0);
        if (f_inflight[i]) begin
          // next beat of this burst: bus address = spec address of the slot the table names
          assert (f_addr[i] + {f_cnt[i], 3'b000} == f_id_base[i] + {tab_beat[i], 3'b000});
          assert (f_cnt[i] <= f_len[i]);
          assert (4'(tab_beat[i]) + 4'(f_len[i] - f_cnt[i]) < f_beats);
        end else begin
          // AR loaded but not yet accepted
          assert (m_axi_arvalid && m_axi_arid == i);
          assert (m_axi_araddr == f_id_base[i] + {tab_beat[i], 3'b000});
          assert (4'(tab_beat[i]) + 4'(m_axi_arlen[2:0]) < f_beats);
        end
      end
  end

`endif

  // ---------------------------------------------------------------- P5 completeness
  // Invariant: once the burst for the slot has been loaded ("issued"), either the slot has been
  // written, or a burst still in flight (or still waiting on AR) will write it. At done without
  // an error every row was issued and nothing is in flight, so the slot has been written.
  (* anyconst *) logic [5:0] f_slot_row;
  (* anyconst *) logic [2:0] f_slot_beat;
  logic             f_slot_hit, f_slot_valid, f_slot_issued;
  logic [MAX_OT-1:0] f_slot_cover;

  always @(posedge clk or negedge rst_n)
    if (!rst_n)                      f_slot_hit <= 1'b0;
    else if (cmd_valid && cmd_ready) f_slot_hit <= 1'b0;
    else if (buf_we && buf_row == f_slot_row && buf_beat == f_slot_beat) f_slot_hit <= 1'b1;

  assign f_slot_valid  = {1'b0, f_slot_row} < f_rows && {1'b0, f_slot_beat} < f_beats;
  assign f_slot_issued = {1'b0, f_slot_row} < row ||
                         ({1'b0, f_slot_row} == row && seg && {1'b0, f_slot_beat} < first_beats);

  for (genvar i = 0; i < MAX_OT; i++) begin : g_cover
    logic [2:0] rem;                   // beats this burst still has to return, after the next one
    assign rem = f_inflight[i] ? f_len[i] - f_cnt[i] : m_axi_arlen[2:0];
    assign f_slot_cover[i] = inflight[i] && tab_row[i] == f_slot_row && tab_beat[i] <= f_slot_beat &&
                             4'(f_slot_beat) <= 4'(tab_beat[i]) + 4'(rem);
  end

  always @(*)
    if (rst_n) begin
`ifndef NO_HELPERS
      // the lemma that makes P5 inductive (refers to the DMA's internals, so it is a helper)
      if (f_busy && f_slot_valid && f_slot_issued) assert (f_slot_hit || f_slot_cover != '0);
      // helper: without an error, the drain starts only after the last row was issued
      if (state == S_DRAIN && !err_seen) assert (row == rows_q && !seg);
`endif
      if (done && !err && f_slot_valid) assert (f_slot_hit);
    end

  // ---------------------------------------------------------------- covers
  always @(posedge clk)
    if (rst_n) begin
      cover (done && !err);
      cover (done && err);
      cover (f_inflight == '1);                                          // 4 bursts outstanding
      cover (m_axi_rvalid && f_rid != 0 && f_inflight[0]);               // ID 1..3 returns before ID 0
      cover (m_axi_rvalid && !m_axi_rlast && $past(m_axi_rvalid && !m_axi_rlast) &&
             m_axi_rid != $past(m_axi_rid));                             // interleaved beats
      cover (m_axi_arvalid && m_axi_arready && seg);                     // second half of a 4 KB split
    end
