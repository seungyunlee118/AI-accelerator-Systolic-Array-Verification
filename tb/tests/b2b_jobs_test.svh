// Back-to-back jobs (vplan F-CSR-06, F-CSR-07, F-DP-05).
//  - Jobs of very different shapes and output modes run one after another with no idle time
//    (big then tiny, INT32 then INT8, ReLU on then off), so state left over from the previous
//    job (buffer contents, tile counters, output mode) would corrupt the next one.
//  - In every other job, while BUSY is high, the test writes START again and then rewrites
//    every configuration register with another job's values. The running job must finish
//    with the configuration it started with (the scoreboard predicts from the original), and
//    the extra START must not launch a second job afterwards.
class b2b_jobs_test extends sa_top_base_test;
  `uvm_component_utils(b2b_jobs_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // While the job runs: START again, then a full set of other configuration values.
  task meddle(sa_job j);
    sa_job       other = sa_job::type_id::create("other");
    uvm_status_e st;
    wait (sys.busy === 1'b1);
    repeat ($urandom_range(0, 30)) @(posedge sys.clk);
    env.regmodel.CTRL.write(st, 32'h1);                         // START while BUSY
    if (!other.randomize()) `uvm_fatal("RAND", "job")
    if ($urandom_range(0, 1)) begin                              // sometimes an illegal one
      other.m = 0;
      other.a_base[2:0] = 3'd3;
    end
    program_job(other);                                          // config writes while BUSY
    if (sys.busy !== 1'b1)
      `uvm_error("TB", "the job ended before the writes were done; the check is not valid (make it longer)")
    `uvm_info("B2B", {"START and new configuration written while BUSY: ", other.convert2string()}, UVM_MEDIUM)
  endtask

  virtual task body();
    sa_job j = sa_job::type_id::create("j");
    int unsigned shapes[10][3] = '{'{64, 64, 64}, '{1, 1, 1}, '{5, 3, 9}, '{64, 1, 64}, '{1, 64, 1},
                                   '{17, 33, 8}, '{4, 4, 4}, '{63, 62, 61}, '{2, 7, 64}, '{9, 1, 1}};
    int unsigned n_rand = 10;
    void'($value$plusargs("JOBS=%d", n_rand));

    for (int i = 0; i < 10 + n_rand; i++) begin
      bit do_meddle = (i % 2 == 0);
      bit rq = i[0], rl = i[1];                    // output mode and ReLU alternate
      bit ok;
      mem_random(40, 50);
      if (i < 10) begin
        int unsigned sm = shapes[i][0], sn = shapes[i][1], sk = shapes[i][2];
        if (!j.randomize() with { m == sm; n == sn; k == sk; req == rq; relu == rl; })
          `uvm_fatal("RAND", "job")
      end else begin
        if (!j.randomize()) `uvm_fatal("RAND", "job")
      end
      // meddling needs a job long enough to still be busy after ~20 register writes
      do_meddle &= (j.m * j.n * j.k >= 4096);

      start_job(j);
      if (do_meddle) meddle(j);
      wait_irq(j, ok);
      if (!ok) return;
      finish_job();
      if (do_meddle) expect_idle(300, "START written while BUSY must be ignored");
    end
  endtask
endclass
