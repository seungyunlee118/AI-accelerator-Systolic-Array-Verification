// First end-to-end test (vplan F-DP-01/02, F-OUT-01): a few directed jobs with a well-behaved
// in-order memory, then a few random ones.
class gemm_smoke_test extends sa_top_base_test;
  `uvm_component_utils(gemm_smoke_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task body();
    sa_job j;
    env.axi.cfg.rd_order = AXI_IN_ORDER;
    env.axi.cfg.lat_max  = 4;

    j = sa_job::type_id::create("j");
    if (!j.randomize() with { m == 4; n == 4; k == 4; req == 0; relu == 0; }) `uvm_fatal("RAND", "job")
    run_job(j);
    if (!j.randomize() with { m == 5; n == 6; k == 7; req == 0; c_gap == 2; }) `uvm_fatal("RAND", "job")
    run_job(j);
    if (!j.randomize() with { m == 13; n == 9; k == 20; req == 1; relu == 1; shift == 7; scale == 300; }) `uvm_fatal("RAND", "job")
    run_job(j);
    if (!j.randomize() with { m == 64; n == 64; k == 64; req == 0; }) `uvm_fatal("RAND", "job")
    run_job(j);
    repeat (4) begin
      if (!j.randomize()) `uvm_fatal("RAND", "job")
      run_job(j);
    end
  endtask
endclass
