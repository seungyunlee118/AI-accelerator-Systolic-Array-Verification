// Reset while idle and in the middle of a job (vplan F-RST-01, F-RST-02; CHK-07, CHK-11).
// For every job phase (A load, B load, compute, C write) a job is started on a slow memory
// (long latency, so reads are in flight), and the asynchronous reset is asserted at a random
// point of that phase, at a random time inside the clock period, for a random length. Then:
//  - the AXI SVA has checked that no VALID was high while reset was asserted;
//  - every register must read its reset value and irq must be low;
//  - a new job must run correctly (no stale ID table entry, buffer or BUSY survives).
// The memory model drops everything in flight on reset, like a memory on the same reset.
// +RESETS=<n> sets the number of resets per phase (default 3).
class reset_midjob_test extends sa_top_base_test;
  `uvm_component_utils(reset_midjob_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task reset_now(string when);
    `uvm_info("RESET", $sformatf("reset %s (controller phase %s, %0d reads and %0d writes outstanding)",
                                 when, sa_phase_of(sys.ctrl_state).name(), env.dma_chk.rd_ot, env.dma_chk.wr_ot), UVM_LOW)
    #($urandom_range(1, 9) * 1ns);                 // anywhere inside the clock period
    pulse_reset($urandom_range(1, 60) * 1ns);
    check_reset_values({"after reset ", when});
  endtask

  virtual task body();
    sa_job       j    = sa_job::type_id::create("j");
    sa_job       good = sa_job::type_id::create("good");
    sa_phase_e   targets[4] = '{PH_A_LOAD, PH_B_LOAD, PH_COMPUTE, PH_C_WRITE};
    int unsigned n_per_phase = 3;
    int unsigned hits[sa_phase_e];
    void'($value$plusargs("RESETS=%d", n_per_phase));

    // ---- F-RST-01: reset while idle, after every register was given a non-reset value.
    // A job that ends with a read error leaves ERR_CODE = 3, IRQ_STATUS.ERR = 1 (not cleared),
    // CYCLES > 0 and IRQ_EN = 3; then every configuration register gets new values. A register
    // that ignores reset cannot hide behind a value that happens to equal its reset value.
    mem_ideal();
    if (!good.randomize() with { m <= 8; n <= 8; k <= 8; }) `uvm_fatal("RAND", "job")
    env.axi.cfg.rd_err_at_beat = 1;
    start_job(good, 4'd3);
    begin
      bit ok;
      wait_irq(good, ok);
    end
    if (!j.randomize() with { m > 1; n > 1; k > 1; shift > 0; scale > 0; req == 1; relu == 1; })
      `uvm_fatal("RAND", "job")
    program_job(j);
    reset_now("while idle");
    run_job(good);

    // ---- F-RST-02: reset in each phase of a running job
    foreach (targets[t])
      repeat (n_per_phase) begin
        bit reached;
        mem_random(120);
        if (!j.randomize() with { m inside {[8:64]}; n inside {[8:64]}; k inside {[8:64]}; })
          `uvm_fatal("RAND", "job")
        start_job(j);
        wait_phase(targets[t], 200000, reached);
        if (!reached) begin
          `uvm_error("RESET", $sformatf("job never reached phase %s: %s", targets[t].name(), j.convert2string()))
          continue;
        end
        repeat ($urandom_range(0, 40)) @(posedge sys.clk);
        begin
          sa_phase_e at = sa_phase_of(sys.ctrl_state);
          hits[at] = hits.exists(at) ? hits[at] + 1 : 1;
        end
        reset_now({"aimed at ", targets[t].name()});

        // the next job must work
        mem_random();
        if (!good.randomize() with { m <= 24; n <= 24; k <= 24; }) `uvm_fatal("RAND", "job")
        run_job(good);
      end

    begin
      string s = "resets landed in phase:";
      foreach (hits[p]) s = {s, $sformatf(" %s=%0d", p.name(), hits[p])};
      `uvm_info("RESET", s, UVM_NONE)
    end
  endtask
endclass
