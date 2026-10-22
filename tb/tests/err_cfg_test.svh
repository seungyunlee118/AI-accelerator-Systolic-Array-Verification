// Configuration errors (vplan F-ERR-01, F-ERR-02, F-ERR-05).
//   BAD_DIM   each of M, N, K set to 0, 65 and 127 (the 7-bit field allows up to 127) while
//             the other two are legal; the legal edges 1 and 64 must still be accepted.
//   BAD_ADDR  each of the six base/stride registers misaligned on its own; C_STRIDE one word
//             below E*N in both output modes; C_STRIDE exactly E*N must be accepted.
//   Priority  BAD_DIM together with BAD_ADDR must report BAD_DIM.
// A rejected job must end at once: ERR_CODE 1 or 2, IRQ_STATUS.ERR, CYCLES 0, BUSY never set,
// no AXI traffic (scoreboard CHK-09 and DMA checker). Every bad job is followed by a good one,
// so an error that sticks is caught.
class err_cfg_test extends sa_top_base_test;
  `uvm_component_utils(err_cfg_test)

  sa_job good, bad;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // A small legal job (keeps the test fast).
  function void small_legal(sa_job j);
    if (!j.randomize() with { m <= 8; n <= 8; k <= 8; }) `uvm_fatal("RAND", "job")
  endfunction

  task bad_then_good(bit [3:0] exp_err);
    if (bad.cfg_err() != exp_err)
      `uvm_fatal("TB", $sformatf("test bug: job has error %0d, not %0d: %s", bad.cfg_err(), exp_err, bad.convert2string()))
    `uvm_info("ERR_CFG", $sformatf("expect ERR_CODE %0d: %s", exp_err, bad.convert2string()), UVM_LOW)
    run_job(bad, exp_err);
    small_legal(good);
    run_job(good);
  endtask

  virtual task body();
    int unsigned bad_dims[] = '{0, 65, 127};
    good = sa_job::type_id::create("good");
    bad  = sa_job::type_id::create("bad");
    mem_ideal();

    // ---- BAD_DIM, one field at a time
    foreach (bad_dims[i])
      for (int f = 0; f < 3; f++) begin
        small_legal(bad);
        case (f)
          0: bad.m = bad_dims[i];
          1: bad.n = bad_dims[i];
          2: bad.k = bad_dims[i];
        endcase
        bad_then_good(4'd1);
      end

    // ---- legal edges of DIMS must be accepted (64 is legal, 65 is not)
    if (!good.randomize() with { m == 64; n == 1;  k == 1;  }) `uvm_fatal("RAND", "job")
    run_job(good);
    if (!good.randomize() with { m == 1;  n == 64; k == 1;  }) `uvm_fatal("RAND", "job")
    run_job(good);
    if (!good.randomize() with { m == 1;  n == 1;  k == 64; }) `uvm_fatal("RAND", "job")
    run_job(good);

    // ---- BAD_ADDR, one register at a time (low 3 bits 1..7)
    for (int f = 0; f < 6; f++) begin
      bit [2:0] low = 3'($urandom_range(1, 7));
      small_legal(bad);
      case (f)
        0: bad.a_base[2:0] = low;
        1: bad.b_base[2:0] = low;
        2: bad.c_base[2:0] = low;
        3: bad.a_stride    = bad.a_stride + low;
        4: bad.b_stride    = bad.b_stride + low;
        5: bad.c_stride    = bad.c_stride + low;
      endcase
      bad_then_good(4'd2);
    end

    // ---- C_STRIDE below E*N (the largest multiple of 8 that is still too small), both modes
    for (int req = 0; req < 2; req++) begin
      if (!bad.randomize() with { req == local::req; n inside {[3:64]}; m <= 8; k <= 8; }) `uvm_fatal("RAND", "job")
      bad.c_stride = 8 * ((bad.e() * bad.n - 1) / 8);
      bad_then_good(4'd2);
    end

    // ---- C_STRIDE exactly E*N is legal: INT32 with N = 8 (32 B), INT8 with N = 16 (16 B)
    if (!good.randomize() with { req == 0; n == 8;  m <= 8; k <= 8; }) `uvm_fatal("RAND", "job")
    good.c_stride = 32;
    run_job(good);
    if (!good.randomize() with { req == 1; n == 16; m <= 8; k <= 8; }) `uvm_fatal("RAND", "job")
    good.c_stride = 16;
    run_job(good);

    // ---- BAD_DIM wins over BAD_ADDR
    for (int f = 0; f < 3; f++) begin
      small_legal(bad);
      case (f)
        0: bad.m = 0;
        1: bad.n = 65;
        2: bad.k = 127;
      endcase
      bad.a_base[2:0] = 3'd4;
      bad.c_stride    = 8;          // also too small for most N
      bad_then_good(4'd1);
    end
  endtask
endclass
