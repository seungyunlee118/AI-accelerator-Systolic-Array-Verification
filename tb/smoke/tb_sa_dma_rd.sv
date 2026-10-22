// Designer smoke test for sa_dma_rd (not the DV environment).
// A small AXI4 read-slave model returns data in order, out of order, or interleaved beat by
// beat, with random latency, gaps and optional RRESP errors. The test checks the buffer
// contents against memory and the read rules of spec §6.1.
module tb_sa_dma_rd;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  // command
  logic        cmd_valid = 0, cmd_ready, cmd_sel = 0;
  logic [31:0] cmd_base = '0;
  logic [15:0] cmd_stride = '0;
  logic [6:0]  cmd_rows = '0, cmd_row_len = '0;
  logic        done, err;
  // buffer write port
  logic        buf_we, buf_sel;
  logic [5:0]  buf_row;
  logic [2:0]  buf_beat;
  logic [63:0] buf_data;
  // AXI
  logic [3:0]  m_axi_arid;
  logic [31:0] m_axi_araddr;
  logic [7:0]  m_axi_arlen;
  logic [2:0]  m_axi_arsize;
  logic [1:0]  m_axi_arburst;
  logic        m_axi_arvalid;
  logic        m_axi_arready = 0;
  logic [3:0]  m_axi_rid = '0;
  logic [63:0] m_axi_rdata = '0;
  logic [1:0]  m_axi_rresp = '0;
  logic        m_axi_rlast = 0, m_axi_rvalid = 0, m_axi_rready;

  sa_dma_rd dut (.*);

  // ---------------------------------------------------------------- memory contents
  function automatic logic [7:0] mem_byte(logic [31:0] a);
    logic [31:0] h;
    h = a * 32'h9E37_79B1;
    return h[31:24] ^ a[7:0];
  endfunction

  function automatic logic [63:0] mem_beat(logic [31:0] a);
    for (int b = 0; b < 8; b++) mem_beat[8*b +: 8] = mem_byte(a + b);
  endfunction

  // ---------------------------------------------------------------- job configuration
  logic [31:0] job_base;
  int          job_stride, job_rows, job_row_len;
  bit          job_sel;
  int          mode;          // 0: in order, 1: out of order, 2: interleaved
  int          lat_max;       // cycles before a burst's data may start
  int          arready_pct;   // chance ARREADY is high in a cycle
  int          rgap_pct;      // chance of an idle cycle on R
  bit          inject_err;

  // ---------------------------------------------------------------- slave state
  typedef struct {
    logic [3:0]  id;
    logic [31:0] addr;
    int          beats;
    int          sent;
    time         ready_at;
    int          err_beat;   // -1: no error
  } burst_t;

  burst_t pend[$];
  bit     id_busy[16];
  int     outstanding = 0;
  bit     consumed = 0;
  int     cur_id = -1;          // burst in progress (modes 0 and 1)
  int     last_id = -1;
  bit     last_was_last = 1;
  bit     err_injected = 0;
  time    err_hs_time = 0;
  bit     err_hs_seen = 0;
  logic   arvalid_q = 0;

  // statistics: proof that the stimulus did what we wanted
  int max_outstanding = 0, ooo_count = 0, interleave_count = 0, split_count = 0, err_jobs = 0;

  int errors = 0;

  // buffer capture
  logic [63:0] shadow [2][64][8];
  bit          wrote  [2][64][8];

  function automatic bit in_row_window(logic [31:0] addr, logic [7:0] len, output bit is_row_start);
    longint lo, hi, w_lo, w_hi;
    bit found;
    lo = addr;
    hi = lo + (longint'(len) + 1) * 8;
    found = 0;
    is_row_start = 0;
    for (int r = 0; r < job_rows; r++) begin
      w_lo = longint'(job_base) + longint'(r) * job_stride;
      w_hi = w_lo + ((job_row_len + 7) / 8) * 8;
      if (lo >= w_lo && hi <= w_hi) found = 1;
      if (lo == w_lo) is_row_start = 1;
    end
    return found;
  endfunction

  // ---------------------------------------------------------------- posedge: consume R, accept AR, capture buffer
  always @(posedge clk) begin
    if (rst_n) begin
      // R beat consumed
      if (m_axi_rvalid && m_axi_rready) begin
        int k[$];
        consumed = 1;
        k = pend.find_first_index(x) with (x.id == m_axi_rid);
        if (k.size() == 0) begin
          errors++; $error("R beat for ID %0d with no outstanding burst", m_axi_rid);
        end else begin
          pend[k[0]].sent++;
          if (m_axi_rresp != 2'b00 && !err_hs_seen) begin
            err_hs_seen = 1;
            err_hs_time = $time;
          end
          if (m_axi_rlast) begin
            if (k[0] != 0) ooo_count++;
            id_busy[m_axi_rid] = 0;
            outstanding--;
            pend.delete(k[0]);
          end
        end
      end

      // new AR loaded after an error was received?
      if (m_axi_arvalid && !arvalid_q && err_hs_seen && ($time - 10) >= err_hs_time) begin
        errors++; $error("new AR loaded after an RRESP error");
      end
      arvalid_q = m_axi_arvalid;

      // AR accepted
      if (m_axi_arvalid && m_axi_arready) begin
        burst_t b;
        bit     row_start;
        if (m_axi_arsize !== 3'd3 || m_axi_arburst !== 2'b01 || m_axi_arlen > 8'd7 ||
            m_axi_araddr[2:0] !== 3'b000) begin
          errors++;
          $error("bad AR shape: addr=%h len=%0d size=%0d burst=%0d",
                 m_axi_araddr, m_axi_arlen, m_axi_arsize, m_axi_arburst);
        end
        if (int'(m_axi_araddr[11:0]) + (int'(m_axi_arlen) + 1) * 8 > 4096) begin
          errors++; $error("AR crosses a 4 KB boundary: addr=%h len=%0d", m_axi_araddr, m_axi_arlen);
        end
        if (m_axi_arid > 4'd3 || id_busy[m_axi_arid]) begin
          errors++; $error("ARID %0d issued while still outstanding (or out of range)", m_axi_arid);
        end
        if (!in_row_window(m_axi_araddr, m_axi_arlen, row_start)) begin
          errors++; $error("AR outside every row window: addr=%h len=%0d", m_axi_araddr, m_axi_arlen);
        end
        if (!row_start) split_count++;
        id_busy[m_axi_arid] = 1;
        outstanding++;
        if (outstanding > 4) begin
          errors++; $error("%0d reads outstanding", outstanding);
        end
        if (outstanding > max_outstanding) max_outstanding = outstanding;
        b.id       = m_axi_arid;
        b.addr     = m_axi_araddr;
        b.beats    = int'(m_axi_arlen) + 1;
        b.sent     = 0;
        b.ready_at = $time + 10 * $urandom_range(1, lat_max);
        b.err_beat = -1;
        if (inject_err && !err_injected && $urandom_range(0, 3) == 0) begin
          b.err_beat   = $urandom_range(0, b.beats - 1);
          err_injected = 1;
        end
        pend.push_back(b);
      end

      // buffer write
      if (buf_we) begin
        shadow[buf_sel][buf_row][buf_beat] = buf_data;
        wrote[buf_sel][buf_row][buf_beat]  = 1;
      end
    end
  end

  // ---------------------------------------------------------------- negedge: drive ARREADY and the next R beat
  always @(negedge clk) begin
    if (rst_n) begin
      m_axi_arready = ($urandom_range(0, 99) < arready_pct);

      if (m_axi_rvalid && !consumed) begin
        // hold: AXI requires RVALID and its payload to stay until the handshake
      end else begin
        int pick;
        int cand[$];
        consumed     = 0;
        m_axi_rvalid = 0;
        pick         = -1;
        if (pend.size() > 0 && $urandom_range(0, 99) >= rgap_pct) begin
          if (mode == 0) begin
            if (pend[0].ready_at <= $time) pick = 0;
          end else if (mode == 1 && cur_id >= 0) begin
            cand = pend.find_first_index(x) with (x.id == cur_id);
            if (cand.size() > 0) pick = cand[0];
          end else begin
            cand = pend.find_index(x) with (x.ready_at <= $time && x.sent < x.beats);
            if (cand.size() > 0) pick = cand[$urandom_range(0, cand.size() - 1)];
          end
        end
        if (pick >= 0) begin
          m_axi_rvalid = 1;
          m_axi_rid    = pend[pick].id;
          m_axi_rdata  = mem_beat(pend[pick].addr + pend[pick].sent * 8);
          m_axi_rlast  = (pend[pick].sent == pend[pick].beats - 1);
          m_axi_rresp  = (pend[pick].sent == pend[pick].err_beat) ? 2'b10 : 2'b00;
          if (last_id >= 0 && last_id != pend[pick].id && !last_was_last) interleave_count++;
          last_id       = pend[pick].id;
          last_was_last = m_axi_rlast;
          cur_id        = m_axi_rlast ? -1 : pend[pick].id;
        end
      end
    end
  end

  // ---------------------------------------------------------------- one job
  task automatic run_job(int mode_i, bit with_err);
    bit got_err, timed_out;

    job_rows    = $urandom_range(1, 64);
    job_row_len = $urandom_range(1, 64);
    case ($urandom_range(0, 3))
      0:       job_stride = 0;                                   // every row at the same address
      1:       job_stride = 8 * $urandom_range(1, 4);            // rows overlap
      default: job_stride = 8 * $urandom_range(8, 40);           // gaps between rows
    endcase
    job_base = {16'($urandom_range(1, 16'hFFF)), 16'h0000} |
               (($urandom_range(0, 1) == 1) ? (32'h1000 - 8 * $urandom_range(1, 8))   // near 4 KB
                                            : 8 * $urandom_range(0, 511));
    job_sel     = $urandom_range(0, 1);
    mode        = mode_i;
    lat_max     = (mode_i == 0) ? $urandom_range(1, 20) : $urandom_range(20, 80);
    arready_pct = $urandom_range(30, 100);
    rgap_pct    = $urandom_range(0, 40);
    inject_err  = with_err;
    err_injected = 0;
    err_hs_seen  = 0;
    cur_id       = -1;
    foreach (wrote[s, r, b]) if (s == job_sel) wrote[s][r][b] = 0;

    @(negedge clk);
    wait (cmd_ready);
    @(negedge clk);
    cmd_base    = job_base;
    cmd_stride  = 16'(job_stride);
    cmd_rows    = 7'(job_rows);
    cmd_row_len = 7'(job_row_len);
    cmd_sel     = job_sel;
    cmd_valid   = 1;
    @(negedge clk);
    cmd_valid   = 0;

    timed_out = 0;
    fork
      begin
        fork
          @(posedge clk iff done);
          begin
            #2_000_000;
            timed_out = 1;
          end
        join_any
        disable fork;
      end
    join
    if (timed_out) begin
      errors++; $error("job did not finish (rows=%0d len=%0d mode=%0d)", job_rows, job_row_len, mode_i);
      return;
    end
    got_err = err;

    if (outstanding != 0 || pend.size() != 0) begin
      errors++; $error("done while %0d bursts still outstanding", outstanding);
    end

    if (err_injected) begin
      err_jobs++;
      if (!got_err) begin errors++; $error("RRESP error was injected but err=0"); end
    end else begin
      if (got_err) begin errors++; $error("err=1 but no error was injected"); end
      for (int r = 0; r < job_rows; r++)
        for (int c = 0; c < job_row_len; c++) begin
          logic [7:0] exp_b, got_b;
          exp_b = mem_byte(job_base + r * job_stride + c);
          got_b = shadow[job_sel][r][c / 8][8 * (c % 8) +: 8];
          if (!wrote[job_sel][r][c / 8] || got_b !== exp_b) begin
            errors++;
            $error("mode=%0d row %0d byte %0d: buffer=%h expected=%h (written=%0b)",
                   mode_i, r, c, got_b, exp_b, wrote[job_sel][r][c / 8]);
            return;
          end
        end
    end
  endtask

  // ---------------------------------------------------------------- test
  initial begin
    repeat (3) @(negedge clk);
    rst_n = 1;
    repeat (2) @(negedge clk);

    for (int m = 0; m < 3; m++)
      repeat (40) run_job(m, 0);
    repeat (40) run_job($urandom_range(0, 2), 1);

    $display("stats: max outstanding=%0d  out-of-order completions=%0d  interleaved beats=%0d  split bursts=%0d  error jobs=%0d",
             max_outstanding, ooo_count, interleave_count, split_count, err_jobs);
    if (max_outstanding < 4) begin errors++; $error("never reached 4 outstanding reads"); end
    if (ooo_count == 0)        begin errors++; $error("no out-of-order completion happened"); end
    if (interleave_count == 0) begin errors++; $error("no interleaved beats happened"); end
    if (split_count == 0)      begin errors++; $error("no 4 KB split happened"); end
    if (err_jobs == 0)         begin errors++; $error("no error job happened"); end

    if (errors == 0) $display("*** DMA_RD SMOKE PASSED ***");
    else             $display("*** DMA_RD SMOKE FAILED: %0d errors ***", errors);
    $finish;
  end
endmodule
