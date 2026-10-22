// Bus errors during a job (vplan F-ERR-03, F-ERR-04, F-ERR-05).
// The memory answers one read beat or one write response with SLVERR. The DUT must then start
// no new burst (DMA checker, CHK-10), still accept every beat and response in flight, end the
// job with ERR_CODE 3 (read) or 4 (write), IRQ_STATUS.ERR only and CYCLES updated, and never
// write outside C (scoreboard). The next job must succeed.
// Read errors hit the first beat, the last beat, or a random beat, with long latency and
// out-of-order/interleaved returns so that up to 4 reads are outstanding when it happens.
// Then one-burst matrices (A with M = 1, K <= 8; B with K = 1, N <= 8) put the error on a read
// that is alone in flight (coverage CG-06 showed A load x 1 outstanding was never hit).
// +JOBS=<n> sets the number of error jobs (default 24).
class err_bus_test extends sa_top_base_test;
  `uvm_component_utils(err_bus_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task body();
    sa_job       j    = sa_job::type_id::create("j");
    sa_job       good = sa_job::type_id::create("good");
    int unsigned n_jobs = 24;
    int unsigned ot_hist[5];                       // reads outstanding at each read error
    void'($value$plusargs("JOBS=%d", n_jobs));

    for (int i = 0; i < n_jobs; i++) begin
      bit          is_rd = (i % 2 == 0);
      int unsigned total, at, where;

      mem_random(150);
      if (!j.randomize() with { m inside {[4:40]}; n inside {[4:40]}; k inside {[4:40]}; })
        `uvm_fatal("RAND", "job")

      // Beats the job reads: rows are 8-byte aligned, so each row is ceil(len/8) beats.
      // Write responses: at least one per tile row of C (more if a row crosses 4 KB).
      total = is_rd ? j.m * ((j.k + 7) / 8) + j.k * ((j.n + 7) / 8)
                    : j.m * ((j.n + 3) / 4);
      where = (i / 2) % 3;                         // 0 first, 1 last, 2 random
      at    = (where == 0) ? 1 : (where == 1) ? total : $urandom_range(1, total);
      if (is_rd) env.axi.cfg.rd_err_at_beat = at;
      else       env.axi.cfg.wr_err_at_resp = at;
      `uvm_info("ERR_BUS", $sformatf("SLVERR on %s %0d of %0d: %s", is_rd ? "read beat" : "write response",
                                     at, total, j.convert2string()), UVM_LOW)

      run_job(j, is_rd ? 4'd3 : 4'd4);
      if (is_rd && env.dma_chk.err_rd_ot inside {[1:4]}) ot_hist[env.dma_chk.err_rd_ot]++;

      if (env.axi.cfg.rd_err_at_beat != 0 || env.axi.cfg.wr_err_at_resp != 0) begin
        `uvm_error("TB", "the injected error never fired (test bug: count too high)")
        env.axi.cfg.rd_err_at_beat = 0;
        env.axi.cfg.wr_err_at_resp = 0;
      end

      // the error must not stick
      mem_random();
      if (!good.randomize() with { m <= 16; n <= 16; k <= 16; }) `uvm_fatal("RAND", "job")
      run_job(good);
    end
    for (int i = 0; i < 4; i++) begin
      bit a_side = (i % 2 == 0);
      mem_random(20);
      if (!j.randomize() with { a_side -> (m == 1 && k <= 8); !a_side -> (k == 1 && n <= 8); })
        `uvm_fatal("RAND", "job")
      // A's only beat is beat 1; B's only beat is the last one of the job
      env.axi.cfg.rd_err_at_beat = a_side ? 1 : j.m * ((j.k + 7) / 8) + j.k * ((j.n + 7) / 8);
      run_job(j, 4'd3);
      if (env.dma_chk.err_rd_ot inside {[1:4]}) ot_hist[env.dma_chk.err_rd_ot]++;
      if (!good.randomize() with { m <= 16; n <= 16; k <= 16; }) `uvm_fatal("RAND", "job")
      run_job(good);
    end
    `uvm_info("ERR_BUS", $sformatf("read errors hit with 1/2/3/4 reads outstanding: %0d/%0d/%0d/%0d",
                                   ot_hist[1], ot_hist[2], ot_hist[3], ot_hist[4]), UVM_NONE)
  endtask
endclass
