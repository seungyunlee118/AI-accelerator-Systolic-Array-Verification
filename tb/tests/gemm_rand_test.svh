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
      mem_random();
      if (!j.randomize()) `uvm_fatal("RAND", "job")
      run_job(j);
    end
  endtask
endclass
