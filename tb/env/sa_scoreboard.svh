// Job-level scoreboard (vplan CHK-01, CHK-02, CHK-03, CHK-09).
//
// start_job(): called by the test just before START. Snapshots A and B from the memory model
//              and computes every expected C byte with the golden model.
// check_job(): called after the job ends. Checks status, interrupt flags and CYCLES, that a
//              configuration error caused no bus traffic, every C byte, that every byte the DUT
//              wrote is a C byte, and that the sentinel around C is untouched.
typedef class sa_top_cov;

class sa_scoreboard extends uvm_component;
  `uvm_component_utils(sa_scoreboard)

  uvm_analysis_imp #(axi_txn, sa_scoreboard) axi_export;

  axi_mem_model mem;
  localparam bit [7:0] SENTINEL = 8'hA5;
  localparam int       GUARD    = 64;      // sentinel bytes before and after the C area

  protected sa_job    job;
  protected bit [3:0] exp_err;
  protected bit [7:0] exp_c [bit [31:0]];  // expected C bytes, by address
  protected int       bursts_this_job;

  int unsigned jobs_ok, jobs_err, elements_checked;
  // proof that the dangerous DMA situations actually happened (precursor of CG-04)
  int unsigned rd_bursts, rd_ooo, rd_interleaved, rd_ot_hist[5];
  // output-stage corners seen in checked elements (precursor of CG-03)
  int unsigned corners [string];
  protected int unsigned job_corners [string];   // of the current job, added once it passes
  protected longint      job_acc [$];             // accumulators of the current job, for CG-03
  sa_top_cov             cov;                     // set by the env

  function new(string name, uvm_component parent);
    super.new(name, parent);
    axi_export = new("axi_export", this);
  endfunction

  function void write(axi_txn t);
    bursts_this_job++;
    if (t.dir == AXI_READ) begin
      rd_bursts++;
      if (t.out_of_order) rd_ooo++;
      if (t.interleaved)  rd_interleaved++;
      if (t.outstanding <= 4) rd_ot_hist[t.outstanding]++;
    end
  endfunction

  function void start_job(sa_job j, bit [3:0] expected_err);
    job     = j;
    exp_err = expected_err;
    exp_c.delete();
    job_corners.delete();
    job_acc.delete();
    mem.clear_dut_written();
    bursts_this_job = 0;
    if (j.cfg_err() != 0) return;          // nothing is computed for a rejected configuration

    for (int r = 0; r < j.m; r++)
      for (int c = 0; c < j.n; c++) begin
        longint acc, v;
        acc = 0;
        for (int i = 0; i < j.k; i++)
          acc += longint'($signed(mem.read_byte(j.a_base + r * j.a_stride + i))) *
                 longint'($signed(mem.read_byte(j.b_base + i * j.b_stride + c)));
        v = sa_gemm_model::outq(acc, j.req, j.relu, j.shift, j.scale);
        job_acc.push_back(acc);
        begin
          string cn = sa_gemm_model::corner(acc, j.req, j.relu, j.shift, j.scale);
          if (cn != "") job_corners[cn] = job_corners.exists(cn) ? job_corners[cn] + 1 : 1;
        end
        for (int b = 0; b < j.e(); b++)
          exp_c[j.c_base + r * j.c_stride + j.e() * c + b] = 8'(v >>> (8 * b));
      end
  endfunction

  function void check_job(bit [31:0] status, bit [31:0] irq_status, bit [31:0] cycles);
    string     tag = $sformatf("job %0d (%s)", jobs_ok + jobs_err + 1, job.convert2string());
    int        bad = 0;
    bit [31:0] lo, hi;

    if (status[0] !== 1'b0) `uvm_error("SB", {tag, ": BUSY still set after the interrupt"})
    if (status[7:4] !== exp_err)
      `uvm_error("SB", $sformatf("%s: ERR_CODE=%0d, expected %0d", tag, status[7:4], exp_err))
    if (irq_status[1:0] !== ((exp_err == 0) ? 2'b01 : 2'b10))
      `uvm_error("SB", $sformatf("%s: IRQ_STATUS=%b, expected %b", tag, irq_status[1:0], (exp_err == 0) ? 2'b01 : 2'b10))

    if (exp_err == 1 || exp_err == 2) begin
      if (cycles !== 0)        `uvm_error("SB", $sformatf("%s: CYCLES=%0d after a configuration error", tag, cycles))
      if (bursts_this_job != 0) `uvm_error("SB", $sformatf("%s: %0d AXI bursts after a configuration error", tag, bursts_this_job))
      if (mem.dut_written.num() != 0) `uvm_error("SB", {tag, ": memory written after a configuration error"})
      jobs_err++;
      return;
    end
    if (exp_err != 0) begin            // bus error: C is undefined, but no stray writes allowed
      if (cycles == 0) `uvm_error("SB", {tag, ": CYCLES is 0 after a bus error (it must be updated)"})
      foreach (mem.dut_written[a])
        if (!in_c_area(a)) `uvm_error("SB", $sformatf("%s: write outside C at %08h", tag, a))
      jobs_err++;
      return;
    end
    if (cycles == 0) `uvm_error("SB", {tag, ": CYCLES is 0 after a successful job"})

    // CHK-01: every C byte
    foreach (exp_c[a]) begin
      bit [7:0] got = mem.read_byte(a);
      if (got !== exp_c[a] && bad++ < 5)
        `uvm_error("SB", $sformatf("%s: C byte at %08h = %02h, expected %02h", tag, a, got, exp_c[a]))
    end
    // CHK-03: every byte the DUT wrote belongs to C
    foreach (mem.dut_written[a])
      if (!exp_c.exists(a) && bad++ < 10)
        `uvm_error("SB", $sformatf("%s: DUT wrote %08h, which is not a C element byte", tag, a))
    // CHK-02: sentinel in row gaps and guard bands
    lo = job.c_base - GUARD;
    hi = job.c_base + job.m * job.c_stride + GUARD;
    for (bit [31:0] a = lo; a < hi; a++)
      if (!exp_c.exists(a) && mem.read_byte(a) !== SENTINEL && bad++ < 15)
        `uvm_error("SB", $sformatf("%s: byte %08h outside C changed to %02h", tag, a, mem.read_byte(a)))

    elements_checked += job.m * job.n;
    foreach (job_corners[c]) corners[c] = (corners.exists(c) ? corners[c] : 0) + job_corners[c];
    if (bad == 0 && cov != null) foreach (job_acc[i]) cov.element(job, job_acc[i]);
    jobs_ok++;
    `uvm_info("SB", $sformatf("%s: OK, %0d cycles, %0d bursts", tag, cycles, bursts_this_job), UVM_LOW)
  endfunction

  protected function bit in_c_area(bit [31:0] a);
    return a >= job.c_base && a < job.c_base + job.m * job.c_stride;
  endfunction

  virtual function void report_phase(uvm_phase phase);
    `uvm_info("SB", $sformatf("checked %0d good jobs (%0d elements) and %0d error jobs",
                              jobs_ok, elements_checked, jobs_err), UVM_NONE)
    `uvm_info("SB", $sformatf("read bursts %0d: out-of-order %0d, interleaved %0d, issued with 1/2/3/4 in flight: %0d/%0d/%0d/%0d",
                              rd_bursts, rd_ooo, rd_interleaved, rd_ot_hist[1], rd_ot_hist[2], rd_ot_hist[3], rd_ot_hist[4]), UVM_NONE)
    if (corners.num() != 0) begin
      string s = "output-stage corners:";
      foreach (corners[c]) s = {s, $sformatf(" %s=%0d", c, corners[c])};
      `uvm_info("SB", s, UVM_NONE)
    end
  endfunction
endclass
