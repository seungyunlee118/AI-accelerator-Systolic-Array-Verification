// Base test for the full chip.
// run_job() runs one job end to end: fill A/B in memory, paint the sentinel, program the
// registers through RAL, start, wait for the interrupt, read status, clear the interrupt, and
// hand everything to the scoreboard and the DMA checker. Its steps are also available on their
// own (start_job / wait_done / finish_job) for tests that act while a job is running.
class sa_top_base_test extends uvm_test;
  `uvm_component_utils(sa_top_base_test)

  sa_env             env;
  virtual sa_sys_if  sys;
  int unsigned       array_n = 4;       // PE array size of this build (tile = array_n x array_n)
  time               job_timeout = 20ms;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = sa_env::type_id::create("env", this);
    if (!uvm_config_db#(virtual sa_sys_if)::get(this, "", "sys_vif", sys))
      `uvm_fatal("NOVIF", "virtual sa_sys_if 'sys_vif' not found in config_db")
    void'(uvm_config_db#(int unsigned)::get(this, "", "array_n", array_n));
    uvm_top.set_timeout(1000ms, 1);
  endfunction

  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    wait (sys.rst_n === 1'b1);
    repeat (2) @(posedge sys.clk);
    body();
    repeat (10) @(posedge sys.clk);
    phase.drop_objection(this);
  endtask

  virtual task body();
  endtask

  // ------------------------------------------------------------ memory personalities
  // Fast, in-order memory: for tests whose subject is not the bus.
  function void mem_ideal();
    env.axi.cfg.rd_order = AXI_IN_ORDER;
    env.axi.cfg.lat_min  = 0;
    env.axi.cfg.lat_max  = 4;
    env.axi.cfg.arready_pct = 100;  env.axi.cfg.awready_pct = 100;  env.axi.cfg.wready_pct = 100;
    env.axi.cfg.rvalid_pct  = 100;  env.axi.cfg.bvalid_pct  = 100;
  endfunction

  // A new random memory: read order, latency and back-pressure on every channel.
  function void mem_random(int unsigned max_lat = 80, int unsigned min_pct = 30);
    env.axi.cfg.rd_order    = axi_rd_order_e'($urandom_range(0, 2));
    env.axi.cfg.lat_min     = 0;
    env.axi.cfg.lat_max     = $urandom_range(0, max_lat);
    env.axi.cfg.arready_pct = $urandom_range(min_pct, 100);
    env.axi.cfg.awready_pct = $urandom_range(min_pct, 100);
    env.axi.cfg.wready_pct  = $urandom_range(min_pct, 100);
    env.axi.cfg.rvalid_pct  = $urandom_range(min_pct, 100);
    env.axi.cfg.bvalid_pct  = $urandom_range(min_pct, 100);
    `uvm_info("JOB", {"memory: ", env.axi.cfg.convert2string()}, UVM_MEDIUM)
  endfunction

  // ------------------------------------------------------------ job data
  // The first byte of every A row and B row holds its row index (DATA_RAND and DATA_SMALL), so
  // two rows are never identical: a bug that swaps rows (e.g. out-of-order data put in the wrong
  // place) cannot hide behind equal data (vplan F-DMA-05 trap).
  function bit [7:0] data_byte(sa_job j, bit is_b, int row, int col);
    bit [7:0] a_sat[6] = '{8'd1, 8'hFF, 8'd2, 8'hFE, 8'd3, 8'hFD};            // +-1, +-2, +-3
    bit [7:0] b_sat[6] = '{8'd127, 8'h80, 8'd64, 8'hC0, 8'd43, 8'hD5};        // 127, -128, +-64, +-43
    case (j.data)
      DATA_SAT:     return is_b ? b_sat[$urandom_range(0, 5)] : a_sat[$urandom_range(0, 5)];
      DATA_SMALL:   return (col == 0) ? 8'(row) : 8'($urandom_range(0, 8) - 4);
      DATA_MAX:     return 8'h80;                                   // -128
      DATA_EXTREME: return $urandom_range(0, 1) ? 8'h80 : 8'h7F;    // -128 or +127
      default:      return (col == 0) ? 8'(row) : 8'($urandom);
    endcase
  endfunction

  function void fill_inputs(sa_job j);
    for (int r = 0; r < j.m; r++)
      for (int c = 0; c < j.k; c++)
        env.axi.mem.write_byte(j.a_base + r * j.a_stride + c, data_byte(j, 0, r, c));
    for (int r = 0; r < j.k; r++)
      for (int c = 0; c < j.n; c++)
        env.axi.mem.write_byte(j.b_base + r * j.b_stride + c, data_byte(j, 1, r, c));
  endfunction

  function void paint_sentinel(sa_job j);
    for (bit [31:0] a = j.c_base - sa_scoreboard::GUARD; a < j.c_base + j.m * j.c_stride + sa_scoreboard::GUARD; a++)
      env.axi.mem.write_byte(a, sa_scoreboard::SENTINEL);
  endfunction

  // ------------------------------------------------------------ job steps
  // Write every configuration register of job j (not IRQ_EN, not START).
  task program_job(sa_job j);
    uvm_status_e st;
    env.regmodel.DIMS.write(st, {9'b0, 7'(j.k), 1'b0, 7'(j.n), 1'b0, 7'(j.m)});
    env.regmodel.A_BASE.write(st, j.a_base);
    env.regmodel.A_STRIDE.write(st, j.a_stride);
    env.regmodel.B_BASE.write(st, j.b_base);
    env.regmodel.B_STRIDE.write(st, j.b_stride);
    env.regmodel.C_BASE.write(st, j.c_base);
    env.regmodel.C_STRIDE.write(st, j.c_stride);
    env.regmodel.QCFG.write(st, {19'b0, 5'(j.shift), 6'b0, j.relu, j.req});
    env.regmodel.QSCALE.write(st, j.scale);
  endtask

  // The job in flight (set when it is started, used by wait_done and finish_job).
  protected sa_job    cur_job;
  protected bit [3:0] cur_err;
  protected bit       cur_poll;
  int unsigned        poll_pct = 25;    // run_job: percent of jobs whose completion is polled

  // Memory for job j: the inputs, and the sentinel around C (nothing for a rejected config).
  function void prepare_memory(sa_job j);
    if (j.cfg_err() == 0) begin
      fill_inputs(j);
      paint_sentinel(j);
    end
  endfunction

  // Prepare memory, program the job and write START. exp_err: the error code the job must end
  // with. poll: IRQ_EN = 0, so software polls IRQ_STATUS instead of waiting for the interrupt.
  task start_job(sa_job j, bit [3:0] exp_err = 0, bit poll = 0);
    uvm_status_e st;
    prepare_memory(j);
    program_job(j);
    env.regmodel.IRQ_EN.write(st, poll ? 32'h0 : 32'h3);
    start_programmed_job(j, exp_err, poll);
  endtask

  // START a job whose memory and registers are already set up (for example programmed while
  // the previous job was still running): arm the checkers and coverage, write CTRL.START only.
  task start_programmed_job(sa_job j, bit [3:0] exp_err = 0, bit poll = 0);
    uvm_status_e st;
    cur_job  = j;
    cur_err  = exp_err;
    cur_poll = poll;
    env.sb.start_job(j, exp_err);
    env.dma_chk.start_job(j, exp_err);
    env.cov.job_start(j);
    env.regmodel.CTRL.write(st, 32'h1);
  endtask

  // Wait until the job is done: for the interrupt, or (polled job) until IRQ_STATUS shows DONE
  // or ERR, with irq staying low because IRQ_EN = 0. ok = 0 (and an error) after job_timeout.
  task wait_done(output bit ok);
    bit timed_out = 0;
    fork
      begin
        fork
          if (cur_poll) poll_irq_status();
          else          wait (sys.irq === 1'b1);
          begin #(job_timeout); timed_out = 1; end
        join_any
        disable fork;
      end
    join
    ok = !timed_out;
    if (timed_out) `uvm_error("JOB", {"job did not finish: ", cur_job.convert2string()})
  endtask

  task poll_irq_status();
    uvm_status_e   st;
    uvm_reg_data_t v;
    do begin
      repeat ($urandom_range(5, 40)) @(posedge sys.clk);
      env.regmodel.IRQ_STATUS.read(st, v);
      if (sys.irq !== 1'b0) `uvm_error("JOB", "irq is high while IRQ_EN = 0")
    end while (v[1:0] == 2'b00);
  endtask

  // Read the job's results, clear the interrupt (W1C), and check everything.
  task finish_job();
    uvm_status_e   st;
    uvm_reg_data_t status, irq_status, cycles;
    env.regmodel.STATUS.read(st, status);
    env.regmodel.IRQ_STATUS.read(st, irq_status);
    env.regmodel.CYCLES.read(st, cycles);
    env.regmodel.IRQ_STATUS.write(st, 32'h3);                 // W1C both flags
    @(negedge sys.clk);
    if (sys.irq !== 1'b0) `uvm_error("JOB", "irq still high after clearing IRQ_STATUS")
    env.sb.check_job(status, irq_status, cycles);
    env.dma_chk.end_job();
    env.cov.job_end(cur_job, cur_err, cur_poll);
  endtask

  // Run one job end to end; poll_pct percent of them are polled instead of interrupt-driven.
  task run_job(sa_job j, bit [3:0] exp_err = 0);
    bit ok;
    start_job(j, exp_err, $urandom_range(1, 100) <= poll_pct);
    wait_done(ok);
    if (ok) finish_job();
  endtask

  // ------------------------------------------------------------ other helpers
  // No job may be running: BUSY stays low, irq stays low and no AR/AW is issued for n cycles.
  task expect_idle(int n, string why);
    int unsigned ar0 = env.dma_chk.n_ar, aw0 = env.dma_chk.n_aw;
    bit          busy_seen = 0, irq_seen = 0;
    repeat (n) begin
      @(sys.mon_cb);
      busy_seen |= (sys.mon_cb.busy === 1'b1);
      irq_seen  |= (sys.mon_cb.irq === 1'b1);
    end
    if (busy_seen || irq_seen || env.dma_chk.n_ar != ar0 || env.dma_chk.n_aw != aw0)
      `uvm_error("IDLE", $sformatf("%s: busy=%0b irq=%0b, %0d AR and %0d AW issued", why, busy_seen,
                                   irq_seen, env.dma_chk.n_ar - ar0, env.dma_chk.n_aw - aw0))
  endtask

  // Assert the asynchronous reset now (at any point of the clock period), hold it for two
  // rising edges plus 'extra' (spec v0.4 §9 minimum), release it away from a rising edge, and
  // reset the RAL mirror to match the hardware.
  task pulse_reset(time extra);
    sys.rst_req = 1'b1;
    repeat (2) @(posedge sys.clk);
    #(extra);
    @(negedge sys.clk);
    sys.rst_req = 1'b0;
    env.regmodel.reset();
    repeat (2) @(posedge sys.clk);
  endtask

  // Every register must read its reset value and irq must be low (CHK-07 after a reset).
  task check_reset_values(string when);
    uvm_reg        regs[$];
    uvm_status_e   st;
    uvm_reg_data_t v;
    env.regmodel.get_registers(regs);
    foreach (regs[i]) begin
      regs[i].read(st, v);
      if (v !== regs[i].get_reset())
        `uvm_error("RESET", $sformatf("%s: %s = %08h, reset value is %08h", when, regs[i].get_name(), v, regs[i].get_reset()))
    end
    if (sys.irq !== 1'b0) `uvm_error("RESET", {when, ": irq is high"})
  endtask

  // Wait until the job is in phase p with exactly n reads in flight (0 if never, in max_cycles).
  task wait_phase_inflight(sa_phase_e p, int n, int max_cycles, output bit reached);
    reached = 0;
    repeat (max_cycles) begin
      @(sys.mon_cb);
      if (sa_phase_of(sys.mon_cb.ctrl_state) == p && env.dma_chk.rd_ot == n) begin
        reached = 1;
        return;
      end
    end
  endtask

  // Wait until the job is in phase p; returns 0 if the job never gets there within max_cycles.
  task wait_phase(sa_phase_e p, int max_cycles, output bit reached);
    reached = 0;
    repeat (max_cycles) begin
      @(sys.mon_cb);
      if (sa_phase_of(sys.mon_cb.ctrl_state) == p) begin
        reached = 1;
        return;
      end
    end
  endtask

  virtual function void report_phase(uvm_phase phase);
    uvm_report_server svr = uvm_report_server::get_server();
    int errs = svr.get_severity_count(UVM_ERROR) + svr.get_severity_count(UVM_FATAL);
    super.report_phase(phase);
    `uvm_info("RESULT", $sformatf("AXI bursts seen: %0d reads, %0d writes",
                                  env.axi.mon.n_reads, env.axi.mon.n_writes), UVM_NONE)
    if (errs == 0) `uvm_info("RESULT", $sformatf("*** TEST PASSED: %s ***", get_type_name()), UVM_NONE)
    else           `uvm_info("RESULT", $sformatf("*** TEST FAILED: %s (%0d errors) ***", get_type_name(), errs), UVM_NONE)
  endfunction
endclass
