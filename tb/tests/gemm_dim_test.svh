// Dimension edges (vplan F-DP-01): M, N and K each take every value of {1, 3, 4, 5, 63, 64}
// (one below, at, and one above the 4x4 tile size, and the top of the range), with the other two
// drawn from the same set, plus the two extreme shapes 1x1x1 and 64x64x64. Both output modes.
class gemm_dim_test extends sa_top_base_test;
  `uvm_component_utils(gemm_dim_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task body();
    sa_job       j = sa_job::type_id::create("j");
    int unsigned edges[6] = '{1, 3, 4, 5, 63, 64};

    mem_random();
    if (!j.randomize() with { m == 1;  n == 1;  k == 1;  }) `uvm_fatal("RAND", "job")
    run_job(j);
    if (!j.randomize() with { m == 64; n == 64; k == 64; }) `uvm_fatal("RAND", "job")
    run_job(j);

    for (int f = 0; f < 3; f++)
      foreach (edges[e]) begin
        int unsigned v = edges[e];
        mem_random();
        if (!j.randomize() with {
              m inside {1, 3, 4, 5, 63, 64};  n inside {1, 3, 4, 5, 63, 64};  k inside {1, 3, 4, 5, 63, 64};
              (f == 0) -> (m == v);  (f == 1) -> (n == v);  (f == 2) -> (k == v); })
          `uvm_fatal("RAND", "job")
        run_job(j);
      end
  endtask
endclass
