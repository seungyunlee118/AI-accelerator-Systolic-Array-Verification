// Base test for the full chip. Provides run_job(): fill A/B in memory, paint the sentinel,
// program the registers through RAL, start, wait for the interrupt, read status, clear the
// interrupt, and hand everything to the scoreboard.
class sa_top_base_test extends uvm_test;
  `uvm_component_utils(sa_top_base_test)

  sa_env             env;
  virtual sa_sys_if  sys;
  time               job_timeout = 20ms;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = sa_env::type_id::create("env", this);
    if (!uvm_config_db#(virtual sa_sys_if)::get(this, "", "sys_vif", sys))
      `uvm_fatal("NOVIF", "virtual sa_sys_if 'sys_vif' not found in config_db")
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

  // ------------------------------------------------------------ job helpers
  // Random input data. The first byte of every A row and B row holds its row index, so two rows
  // are never identical: a bug that swaps rows (e.g. out-of-order data put in the wrong place)
  // cannot hide behind equal data (vplan F-DMA-05 trap).
  function void fill_inputs(sa_job j);
    for (int r = 0; r < j.m; r++)
      for (int c = 0; c < j.k; c++)
        env.axi.mem.write_byte(j.a_base + r * j.a_stride + c, (c == 0) ? 8'(r) : 8'($urandom));
    for (int r = 0; r < j.k; r++)
      for (int c = 0; c < j.n; c++)
        env.axi.mem.write_byte(j.b_base + r * j.b_stride + c, (c == 0) ? 8'(r) : 8'($urandom));
  endfunction

  function void paint_sentinel(sa_job j);
    for (bit [31:0] a = j.c_base - sa_scoreboard::GUARD; a < j.c_base + j.m * j.c_stride + sa_scoreboard::GUARD; a++)
      env.axi.mem.write_byte(a, sa_scoreboard::SENTINEL);
  endfunction

  // Run one job end to end. exp_err: the error code the job must end with.
  task run_job(sa_job j, bit [3:0] exp_err = 0);
    uvm_status_e st;
    uvm_reg_data_t status, irq_status, cycles;
    bit timed_out;

    if (j.cfg_err() == 0) begin
      fill_inputs(j);
      paint_sentinel(j);
    end
    env.sb.start_job(j, exp_err);

    env.regmodel.DIMS.write(st, {9'b0, 7'(j.k), 1'b0, 7'(j.n), 1'b0, 7'(j.m)});
    env.regmodel.A_BASE.write(st, j.a_base);
    env.regmodel.A_STRIDE.write(st, j.a_stride);
    env.regmodel.B_BASE.write(st, j.b_base);
    env.regmodel.B_STRIDE.write(st, j.b_stride);
    env.regmodel.C_BASE.write(st, j.c_base);
    env.regmodel.C_STRIDE.write(st, j.c_stride);
    env.regmodel.QCFG.write(st, {19'b0, 5'(j.shift), 6'b0, j.relu, j.req});
    env.regmodel.QSCALE.write(st, j.scale);
    env.regmodel.IRQ_EN.write(st, 32'h3);
    env.regmodel.CTRL.write(st, 32'h1);

    timed_out = 0;
    fork
      begin
        fork
          wait (sys.irq === 1'b1);
          begin #(job_timeout); timed_out = 1; end
        join_any
        disable fork;
      end
    join
    if (timed_out) begin
      `uvm_error("JOB", {"no interrupt: ", j.convert2string()})
      return;
    end

    env.regmodel.STATUS.read(st, status);
    env.regmodel.IRQ_STATUS.read(st, irq_status);
    env.regmodel.CYCLES.read(st, cycles);
    env.regmodel.IRQ_STATUS.write(st, 32'h3);                 // W1C both flags
    @(negedge sys.clk);
    if (sys.irq !== 1'b0) `uvm_error("JOB", "irq still high after clearing IRQ_STATUS")

    env.sb.check_job(status, irq_status, cycles);
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
