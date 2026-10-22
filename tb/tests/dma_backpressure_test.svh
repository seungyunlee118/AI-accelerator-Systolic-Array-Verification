// Back-pressure (vplan F-DMA-07): every READY and VALID the memory drives is high in only
// 5..30% of cycles, so the DMA sees long and random stalls on all five channels. The AXI SVA
// checks VALID is held and the payload stays stable while stalled; the scoreboard checks C.
class dma_backpressure_test extends sa_top_base_test;
  `uvm_component_utils(dma_backpressure_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task body();
    sa_job       j = sa_job::type_id::create("j");
    int unsigned n_jobs = 12;
    void'($value$plusargs("JOBS=%d", n_jobs));

    repeat (n_jobs) begin
      mem_random(40, 5);
      env.axi.cfg.arready_pct = $urandom_range(5, 30);
      env.axi.cfg.awready_pct = $urandom_range(5, 30);
      env.axi.cfg.wready_pct  = $urandom_range(5, 30);
      env.axi.cfg.rvalid_pct  = $urandom_range(5, 30);
      env.axi.cfg.bvalid_pct  = $urandom_range(5, 30);
      if (!j.randomize() with { m <= 32; n <= 32; k <= 32; }) `uvm_fatal("RAND", "job")
      run_job(j);
    end
  endtask
endclass
