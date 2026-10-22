// Random jobs with random memory behavior (vplan F-DP-01..03, F-DMA-02..07, F-OUT-01..03):
// every job draws new dimensions, output mode, quantization, bases/strides and a new memory
// personality: read order (in order / out of order / interleaved), latency and back-pressure.
// +JOBS=<n> sets the number of jobs (default 25).
class gemm_rand_test extends sa_top_base_test;
  `uvm_component_utils(gemm_rand_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task body();
    sa_job       j = sa_job::type_id::create("j");
    int unsigned n_jobs = 25;
    void'($value$plusargs("JOBS=%d", n_jobs));

    repeat (n_jobs) begin
      env.axi.cfg.rd_order    = axi_rd_order_e'($urandom_range(0, 2));
      env.axi.cfg.lat_min     = 0;
      env.axi.cfg.lat_max     = $urandom_range(0, 80);
      env.axi.cfg.arready_pct = $urandom_range(30, 100);
      env.axi.cfg.awready_pct = $urandom_range(30, 100);
      env.axi.cfg.wready_pct  = $urandom_range(30, 100);
      env.axi.cfg.rvalid_pct  = $urandom_range(30, 100);
      env.axi.cfg.bvalid_pct  = $urandom_range(30, 100);
      if (!j.randomize()) `uvm_fatal("RAND", "job")
      `uvm_info("JOB", {"memory: ", env.axi.cfg.convert2string()}, UVM_MEDIUM)
      run_job(j);
    end
  endtask
endclass
