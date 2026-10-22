// Designer smoke test for the full DUT (sa_top). Not the DV environment.
// Plays the CPU (AXI4-Lite) and the memory (AXI4 slave), runs whole GEMM jobs and checks:
// every C element, that nothing outside C was written (sentinel), the error codes, DONE/ERR,
// irq, CYCLES, and that configuration errors produce no bus traffic.
module tb_sa_top;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  // ---------------------------------------------------------------- DUT ports
  logic [31:0] s_axil_awaddr = '0, s_axil_wdata = '0, s_axil_araddr = '0;
  logic        s_axil_awvalid = 0, s_axil_wvalid = 0, s_axil_bready = 0;
  logic        s_axil_arvalid = 0, s_axil_rready = 0;
  logic [3:0]  s_axil_wstrb = '0;
  logic        s_axil_awready, s_axil_wready, s_axil_bvalid, s_axil_arready, s_axil_rvalid;
  logic [1:0]  s_axil_bresp, s_axil_rresp;
  logic [31:0] s_axil_rdata;

  logic [3:0]  m_axi_awid, m_axi_arid;
  logic [31:0] m_axi_awaddr, m_axi_araddr;
  logic [7:0]  m_axi_awlen, m_axi_arlen;
  logic [2:0]  m_axi_awsize, m_axi_arsize;
  logic [1:0]  m_axi_awburst, m_axi_arburst;
  logic        m_axi_awvalid, m_axi_wvalid, m_axi_wlast, m_axi_bready, m_axi_arvalid, m_axi_rready;
  logic [63:0] m_axi_wdata;
  logic [7:0]  m_axi_wstrb;
  logic        m_axi_awready = 0, m_axi_wready = 0, m_axi_bvalid = 0;
  logic        m_axi_arready = 0, m_axi_rvalid = 0, m_axi_rlast = 0;
  logic [3:0]  m_axi_bid = '0, m_axi_rid = '0;
  logic [1:0]  m_axi_bresp = '0, m_axi_rresp = '0;
  logic [63:0] m_axi_rdata = '0;
  logic        irq;

  sa_top dut (.*);

  int errors = 0;
  localparam int MAX_ERRORS = 10;
  always @(errors)
    if (errors >= MAX_ERRORS) begin
      $display("*** TOP SMOKE FAILED: stopped after %0d errors ***", errors);
      $finish;
    end
  initial begin
    #200_000_000;
    $display("*** TOP SMOKE FAILED: global timeout ***");
    $finish;
  end

  // ---------------------------------------------------------------- CSR offsets
  localparam logic [7:0] R_CTRL = 8'h00, R_STATUS = 8'h04, R_IRQ_EN = 8'h08, R_IRQ_ST = 8'h0C,
                         R_DIMS = 8'h10, R_ABASE = 8'h14, R_ASTR = 8'h18, R_BBASE = 8'h1C,
                         R_BSTR = 8'h20, R_CBASE = 8'h24, R_CSTR = 8'h28, R_CYCLES = 8'h2C,
                         R_QCFG = 8'h34, R_QSCALE = 8'h38;

  // ---------------------------------------------------------------- AXI4-Lite master (CPU)
  task automatic axil_write(logic [7:0] addr, logic [31:0] data);
    @(negedge clk);
    s_axil_awaddr = 32'(addr); s_axil_awvalid = 1;
    s_axil_wdata  = data;      s_axil_wstrb   = 4'hF; s_axil_wvalid = 1;
    fork
      begin @(posedge clk); while (!s_axil_awready) @(posedge clk); @(negedge clk); s_axil_awvalid = 0; end
      begin @(posedge clk); while (!s_axil_wready)  @(posedge clk); @(negedge clk); s_axil_wvalid  = 0; end
    join
    s_axil_bready = 1;
    @(posedge clk); while (!s_axil_bvalid) @(posedge clk);
    if (s_axil_bresp !== 2'b00) begin errors++; $error("CSR write %02h got BRESP %0d", addr, s_axil_bresp); end
    @(negedge clk); s_axil_bready = 0;
  endtask

  task automatic axil_read(logic [7:0] addr, output logic [31:0] data);
    @(negedge clk); s_axil_araddr = 32'(addr); s_axil_arvalid = 1; s_axil_rready = 1;
    @(posedge clk); while (!s_axil_arready) @(posedge clk);
    @(negedge clk); s_axil_arvalid = 0;
    @(posedge clk); while (!s_axil_rvalid) @(posedge clk);
    data = s_axil_rdata;
    @(negedge clk); s_axil_rready = 0;
  endtask

  // ---------------------------------------------------------------- memory model (AXI4 slave)
  bit [7:0] mem [bit [31:0]];
  function automatic bit [7:0] rd8(bit [31:0] a);
    return mem.exists(a) ? mem[a] : 8'h00;
  endfunction

  typedef struct { logic [3:0] id; logic [31:0] addr; int beats; int sent; time ready_at; } rd_burst_t;
  typedef struct { logic [31:0] addr; int beats; int got; } wr_burst_t;
  rd_burst_t rd_q[$];
  wr_burst_t aw_q[$];
  int        b_pending = 0;     // write bursts whose B is owed
  bit        r_consumed = 0, b_consumed = 0;

  // per-job knobs and bookkeeping
  bit  inject_rd_err, inject_wr_err, rd_err_done, wr_err_done;
  int  r_beats_job, ar_count, aw_count, bad_writes;
  // current job (used by the write-containment check)
  int          j_m, j_n, j_k, j_e;
  logic [31:0] j_cbase;
  int          j_cstr;

  function automatic bit is_c_byte(logic [31:0] a);
    longint d;
    d = longint'(a) - longint'(j_cbase);
    if (d < 0) return 0;
    return (d / j_cstr < j_m) && (d % j_cstr < j_e * j_n);
  endfunction

  always @(posedge clk) begin
    if (rst_n) begin
      // AR accepted
      if (m_axi_arvalid && m_axi_arready) begin
        rd_burst_t b;
        b.id = m_axi_arid; b.addr = m_axi_araddr; b.beats = int'(m_axi_arlen) + 1; b.sent = 0;
        b.ready_at = $time + 10 * $urandom_range(0, 6);
        rd_q.push_back(b);
        ar_count++;
      end
      // R beat consumed
      if (m_axi_rvalid && m_axi_rready) begin
        r_consumed = 1;
        rd_q[0].sent++;
        if (m_axi_rlast) void'(rd_q.pop_front());
      end
      // AW accepted
      if (m_axi_awvalid && m_axi_awready) begin
        wr_burst_t w;
        w.addr = m_axi_awaddr; w.beats = int'(m_axi_awlen) + 1; w.got = 0;
        aw_q.push_back(w);
        aw_count++;
        if (m_axi_awaddr[11:0] + (int'(m_axi_awlen) + 1) * 8 > 4096) begin
          errors++; $error("write burst crosses 4 KB: addr=%h len=%0d", m_axi_awaddr, m_axi_awlen);
        end
      end
      // W beat
      if (m_axi_wvalid && m_axi_wready) begin
        if (aw_q.size() == 0) begin
          errors++; $error("W beat before its AW");
        end else begin
          for (int b = 0; b < 8; b++)
            if (m_axi_wstrb[b]) begin
              logic [31:0] a;
              a = aw_q[0].addr + 8 * aw_q[0].got + b;
              if (!is_c_byte(a)) begin
                bad_writes++;
                errors++; $error("write to a byte outside C: %h", a);
              end
              mem[a] = m_axi_wdata[8*b +: 8];
            end
          aw_q[0].got++;
          if (m_axi_wlast) begin
            if (aw_q[0].got != aw_q[0].beats) begin
              errors++; $error("WLAST on beat %0d of %0d", aw_q[0].got, aw_q[0].beats);
            end
            void'(aw_q.pop_front());
            b_pending++;
          end
        end
      end
      // B consumed
      if (m_axi_bvalid && m_axi_bready) begin
        b_consumed = 1;
        b_pending--;
      end
    end
  end

  always @(negedge clk) begin
    if (rst_n) begin
      m_axi_arready = ($urandom_range(0, 3) != 0);
      m_axi_awready = ($urandom_range(0, 3) != 0);
      m_axi_wready  = ($urandom_range(0, 3) != 0);

      // R channel: in order, random latency and gaps
      if (!(m_axi_rvalid && !r_consumed)) begin
        r_consumed   = 0;
        m_axi_rvalid = 0;
        if (rd_q.size() > 0 && rd_q[0].ready_at <= $time && $urandom_range(0, 3) != 0) begin
          m_axi_rvalid = 1;
          m_axi_rid    = rd_q[0].id;
          for (int b = 0; b < 8; b++) m_axi_rdata[8*b +: 8] = rd8(rd_q[0].addr + 8 * rd_q[0].sent + b);
          m_axi_rlast  = (rd_q[0].sent == rd_q[0].beats - 1);
          r_beats_job++;
          m_axi_rresp  = 2'b00;
          if (inject_rd_err && !rd_err_done && r_beats_job == 3) begin
            m_axi_rresp = 2'b10;
            rd_err_done = 1;
          end
        end
      end

      // B channel
      if (!(m_axi_bvalid && !b_consumed)) begin
        b_consumed   = 0;
        m_axi_bvalid = 0;
        if (b_pending > 0 && $urandom_range(0, 2) != 0) begin
          m_axi_bvalid = 1;
          m_axi_bresp  = 2'b00;
          if (inject_wr_err && !wr_err_done) begin
            m_axi_bresp = 2'b10;
            wr_err_done = 1;
          end
        end
      end
    end
  end

  // ---------------------------------------------------------------- reference model (spec §7)
  function automatic longint outq(longint acc, bit req, bit relu, int sh, longint sc);
    longint p, r;
    if (!req) return (relu && acc < 0) ? 0 : acc;
    p = acc * sc;
    r = (sh == 0) ? p : ((p + (64'sd1 <<< (sh - 1))) >>> sh);
    if (relu && r < 0) r = 0;
    return (r > 127) ? 127 : (r < -128) ? -128 : r;
  endfunction

  // ---------------------------------------------------------------- one job
  int jobs = 0, err_jobs = 0;

  task automatic run_job(string name, int m, int n, int k, bit req, bit relu, int sh, int sc,
                         logic [31:0] abase, int astr, logic [31:0] bbase, int bstr,
                         logic [31:0] cbase, int cstr, int exp_err,
                         bit rd_err = 0, bit wr_err = 0);
    logic signed [7:0] A [64][64];
    logic signed [7:0] B [64][64];
    logic [31:0] st, irq_st, cyc, rd;
    int          e, ar0, aw0;
    bit          timed_out;

    e = req ? 1 : 4;
    // inputs
    for (int r = 0; r < m && r < 64; r++) for (int c = 0; c < k && c < 64; c++) mem[abase + r * astr + c] = $urandom;
    for (int r = 0; r < k && r < 64; r++) for (int c = 0; c < n && c < 64; c++) mem[bbase + r * bstr + c] = $urandom;
    for (int r = 0; r < m && r < 64; r++) for (int c = 0; c < k && c < 64; c++) A[r][c] = rd8(abase + r * astr + c);
    for (int r = 0; r < k && r < 64; r++) for (int c = 0; c < n && c < 64; c++) B[r][c] = rd8(bbase + r * bstr + c);
    // sentinel over the whole C area plus 64-byte guard bands
    if (exp_err == 0)
      for (longint a = longint'(cbase) - 64; a < longint'(cbase) + m * cstr + 64; a++) mem[32'(a)] = 8'hA5;

    j_m = m; j_n = n; j_k = k; j_e = e; j_cbase = cbase; j_cstr = cstr;
    inject_rd_err = rd_err; inject_wr_err = wr_err; rd_err_done = 0; wr_err_done = 0;
    r_beats_job = 0; bad_writes = 0;

    axil_write(R_DIMS,   {9'b0, 7'(k), 1'b0, 7'(n), 1'b0, 7'(m)});
    axil_write(R_ABASE,  abase);  axil_write(R_ASTR, 32'(astr));
    axil_write(R_BBASE,  bbase);  axil_write(R_BSTR, 32'(bstr));
    axil_write(R_CBASE,  cbase);  axil_write(R_CSTR, 32'(cstr));
    axil_write(R_QCFG,   {19'b0, 5'(sh), 6'b0, relu, req});
    axil_write(R_QSCALE, 32'(sc));
    axil_write(R_IRQ_EN, 32'h3);
    ar0 = ar_count; aw0 = aw_count;
    axil_write(R_CTRL,   32'h1);

    timed_out = 0;
    fork
      begin
        fork
          @(posedge clk iff irq);
          begin #50_000_000; timed_out = 1; end
        join_any
        disable fork;
      end
    join
    jobs++;
    if (timed_out) begin errors++; $error("%s: no interrupt", name); return; end

    axil_read(R_STATUS, st);
    axil_read(R_IRQ_ST, irq_st);
    axil_read(R_CYCLES, cyc);
    if (st[0] !== 1'b0)              begin errors++; $error("%s: BUSY still set", name); end
    if (int'(st[7:4]) != exp_err)    begin errors++; $error("%s: ERR_CODE=%0d expected %0d", name, st[7:4], exp_err); end
    if (irq_st[1:0] !== ((exp_err == 0) ? 2'b01 : 2'b10)) begin
      errors++; $error("%s: IRQ_STATUS=%b", name, irq_st[1:0]);
    end
    if ((exp_err == 1 || exp_err == 2) && cyc !== 0) begin errors++; $error("%s: CYCLES=%0d after a config error", name, cyc); end
    if ((exp_err == 0) && cyc == 0)                  begin errors++; $error("%s: CYCLES is 0", name); end
    if ((exp_err == 1 || exp_err == 2) && (ar_count != ar0 || aw_count != aw0)) begin
      errors++; $error("%s: bus traffic after a configuration error", name);
    end
    axil_write(R_IRQ_ST, 32'h3);           // W1C
    @(negedge clk);
    if (irq !== 1'b0) begin errors++; $error("%s: irq still high after clearing", name); end
    if (exp_err != 0) begin err_jobs++; return; end

    // results and sentinel
    for (int r = 0; r < m; r++)
      for (int c = 0; c < n; c++) begin
        longint acc, v;
        acc = 0;
        for (int i = 0; i < k; i++) acc += longint'(A[r][i]) * longint'(B[i][c]);
        v = outq(acc, req, relu, sh, sc);
        for (int b = 0; b < e; b++) begin
          logic [7:0] got_b, exp_b;
          got_b = rd8(cbase + r * cstr + e * c + b);
          exp_b = 8'(v >>> (8 * b));
          if (got_b !== exp_b) begin
            errors++;
            $error("%s: C[%0d][%0d] byte %0d = %h, expected %h (acc=%0d)", name, r, c, b, got_b, exp_b, acc);
            return;
          end
        end
      end
    for (longint a = longint'(cbase) - 64; a < longint'(cbase) + m * cstr + 64; a++)
      if (!is_c_byte(32'(a)) && rd8(32'(a)) !== 8'hA5) begin
        errors++; $error("%s: byte %h outside C was changed", name, 32'(a));
        return;
      end
    $display("  %-24s M=%2d N=%2d K=%2d %s ok, %0d cycles", name, m, n, k, req ? "INT8 " : "INT32", cyc);
  endtask

  // ---------------------------------------------------------------- test
  initial begin
    repeat (3) @(negedge clk);
    rst_n = 1;
    repeat (2) @(negedge clk);

    //           name                   M   N   K  req relu sh  scale  A base        Astr  B base        Bstr  C base        Cstr  err
    run_job("basic_4x4x4",              4,  4,  4, 0, 0,  0, 0,     32'h0001_0000,  8, 32'h0002_0000,  8, 32'h0003_0000,  16, 0);
    run_job("edge_5x6x7_gaps",          5,  6,  7, 0, 0,  0, 0,     32'h0001_0000, 16, 32'h0002_0000, 16, 32'h0003_0000,  40, 0);
    run_job("int8_relu_13x9x20",       13,  9, 20, 1, 1,  7, 300,   32'h0001_0000, 24, 32'h0002_0000, 16, 32'h0003_0000,  16, 0);
    run_job("int8_c_cross_4k",          6,  9,  5, 1, 0,  3, 5,     32'h0001_0000,  8, 32'h0002_0000, 16, 32'h0000_2FF8,  16, 0);
    run_job("int32_c_cross_4k",         3,  7,  9, 0, 1,  0, 0,     32'h0001_0000, 16, 32'h0002_0000,  8, 32'h0000_5FF8,  32, 0);
    run_job("a_rows_cross_4k",          9,  4, 40, 0, 0,  0, 0,     32'h0000_7FE0, 48, 32'h0002_0000,  8, 32'h0003_0000,  16, 0);
    run_job("max_64x64x64",            64, 64, 64, 0, 0,  0, 0,     32'h0001_0000, 64, 32'h0002_0000, 64, 32'h0003_0000, 256, 0);
    run_job("bad_dim_m0",               0,  4,  4, 0, 0,  0, 0,     32'h0001_0000,  8, 32'h0002_0000,  8, 32'h0003_0000,  16, 1);
    run_job("bad_dim_k65",              4,  4, 65, 0, 0,  0, 0,     32'h0001_0000,  8, 32'h0002_0000,  8, 32'h0003_0000,  16, 1);
    run_job("bad_addr_abase",           4,  4,  4, 0, 0,  0, 0,     32'h0001_0004,  8, 32'h0002_0000,  8, 32'h0003_0000,  16, 2);
    run_job("bad_addr_cstride",         4,  5,  4, 0, 0,  0, 0,     32'h0001_0000,  8, 32'h0002_0000,  8, 32'h0003_0000,  16, 2);
    run_job("rd_error",                 8,  8,  8, 0, 0,  0, 0,     32'h0001_0000,  8, 32'h0002_0000,  8, 32'h0003_0000,  32, 3, 1, 0);
    run_job("after_rd_error",           4,  4,  4, 0, 0,  0, 0,     32'h0001_0000,  8, 32'h0002_0000,  8, 32'h0003_0000,  16, 0);
    run_job("wr_error",                 8,  8,  8, 0, 0,  0, 0,     32'h0001_0000,  8, 32'h0002_0000,  8, 32'h0003_0000,  32, 4, 0, 1);
    run_job("after_wr_error",           4,  4,  4, 0, 0,  0, 0,     32'h0001_0000,  8, 32'h0002_0000,  8, 32'h0003_0000,  16, 0);

    // random jobs
    repeat (30) begin
      int m, n, k, e, astr, bstr, cstr, sh, sc;
      bit req, relu;
      m = $urandom_range(1, 64); n = $urandom_range(1, 64); k = $urandom_range(1, 64);
      req = $urandom_range(0, 1); relu = $urandom_range(0, 1);
      sh = $urandom_range(0, 20); sc = $urandom_range(0, 65535);
      e = req ? 1 : 4;
      astr = 8 * ((k + 7) / 8 + $urandom_range(0, 2));
      bstr = 8 * ((n + 7) / 8 + $urandom_range(0, 2));
      cstr = 8 * ((e * n + 7) / 8 + $urandom_range(0, 2));
      run_job("random", m, n, k, req, relu, sh, sc,
              32'h0001_0000 + 8 * $urandom_range(0, 511), astr,
              32'h0002_0000 + 8 * $urandom_range(0, 511), bstr,
              32'h0003_0000 + 8 * $urandom_range(0, 511), cstr, 0);
    end

    $display("jobs=%0d (error jobs %0d)", jobs, err_jobs);
    if (errors == 0) $display("*** TOP SMOKE PASSED ***");
    else             $display("*** TOP SMOKE FAILED: %0d errors ***", errors);
    $finish;
  end
endmodule
