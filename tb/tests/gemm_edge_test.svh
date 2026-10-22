// Edge tiles and write containment (vplan F-DP-02, F-DMA-06).
// Every combination of M mod 4, N mod 4 and output mode (4 x 4 x 2 = 32 jobs) runs twice: once
// with C rows packed (C_STRIDE = E*N rounded up to 8 bytes) and once with a gap between rows,
// and half of the jobs put C near the end of a 4 KB page so C rows are split. The scoreboard
// checks every C byte, that no byte outside the C elements changed (sentinel in row gaps and in
// a 64-byte guard band), and that every byte the DUT wrote is a C element byte.
class gemm_edge_test extends sa_top_base_test;
  `uvm_component_utils(gemm_edge_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task body();
    sa_job j = sa_job::type_id::create("j");

    for (int pass = 0; pass < 2; pass++)
      for (int rm = 0; rm < 4; rm++)
        for (int rn = 0; rn < 4; rn++)
          for (int rq = 0; rq < 2; rq++) begin
            bit near_page_end = $urandom_range(0, 1);
            mem_random();
            if (!j.randomize() with {
                  m % 4 == rm;  n % 4 == rn;  req == rq;
                  (pass == 0) -> (c_gap == 0);  (pass == 1) -> (c_gap > 0);
                  near_page_end -> (c_base[11:0] >= 12'hF00); })
              `uvm_fatal("RAND", "job")
            run_job(j);
          end
  endtask
endclass
