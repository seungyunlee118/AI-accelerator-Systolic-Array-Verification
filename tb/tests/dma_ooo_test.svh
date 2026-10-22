// Outstanding, out-of-order and interleaved reads (vplan F-DMA-04, F-DMA-05).
// Read latency of 20..200 cycles keeps up to 4 bursts in flight; the memory returns them out of
// order or interleaved beat by beat. Jobs alternate short rows (K, N <= 8: one beat per row) and
// long rows (K, N = 64: 8-beat bursts, so interleaving has beats to mix).
// Rows hold unique data (row index in the first byte), so a beat put in the wrong row breaks C.
// The test fails if the situations it exists for never happened: 4 reads outstanding,
// out-of-order completion, and interleaving.
class dma_ooo_test extends sa_top_base_test;
  `uvm_component_utils(dma_ooo_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task body();
    sa_job       j = sa_job::type_id::create("j");
    int unsigned n_jobs = 16;
    void'($value$plusargs("JOBS=%d", n_jobs));

    for (int i = 0; i < n_jobs; i++) begin
      env.axi.cfg.rd_order = (i % 2 == 0) ? AXI_OUT_OF_ORDER : AXI_INTERLEAVE;
      env.axi.cfg.lat_min  = 20;
      env.axi.cfg.lat_max  = 200;
      env.axi.cfg.arready_pct = 100;  env.axi.cfg.rvalid_pct = $urandom_range(60, 100);
      env.axi.cfg.awready_pct = 100;  env.axi.cfg.wready_pct = 100;  env.axi.cfg.bvalid_pct = 100;
      if ((i / 2) % 2 == 0) begin
        if (!j.randomize() with { k <= 8; n <= 8; m inside {[16:64]}; }) `uvm_fatal("RAND", "job")
      end else begin
        if (!j.randomize() with { k == 64; n == 64; m inside {[4:32]}; }) `uvm_fatal("RAND", "job")
      end
      run_job(j);
    end

    if (env.sb.rd_ot_hist[4] == 0) `uvm_error("DMA_OOO", "never had 4 reads outstanding")
    if (env.sb.rd_ooo == 0)        `uvm_error("DMA_OOO", "no read burst ever completed out of order")
    if (env.sb.rd_interleaved == 0) `uvm_error("DMA_OOO", "no read burst was ever interleaved")
  endtask
endclass
