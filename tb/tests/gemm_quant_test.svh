// Output stage corners (vplan F-DP-04, F-OUT-01..03).
// INT8 jobs sweep SCALE over {0, 1, 2, random, 65535} x SHIFT over {0, 1, random, 30, 31}, each
// with a data pattern chosen for the corner it can reach:
//   DATA_MAX      all -128, so the accumulator reaches K * 16384 = 1,048,576 (F-DP-04)
//   DATA_EXTREME  -128/+127 mix: huge positive and negative sums, clamping at both ends
//   DATA_SMALL    values -4..4: odd sums, so SHIFT >= 1 makes exact .5 ties of both signs
// plus INT32 jobs with ReLU on and off. ReLU is random. Then K = 1 jobs with DATA_SAT put
// results exactly on the saturation edges, 128 and -129 (found by mutation: an off-by-one
// clamp `r > 128` survived every random job, because random data never produced exactly 128).
// The scoreboard counts the corners it checked and the test fails if any of them never
// happened, so a too-weak stimulus cannot pass silently.
class gemm_quant_test extends sa_top_base_test;
  `uvm_component_utils(gemm_quant_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task body();
    sa_job       j = sa_job::type_id::create("j");
    int unsigned scales[5] = '{0, 1, 2, 0, 65535};
    int unsigned shifts[5] = '{0, 1, 0, 30, 31};
    string       must[$]   = '{"clamp_hi", "clamp_lo", "relu_zero", "tie_pos", "tie_neg",
                               "sat_edge_hi", "sat_edge_lo"};

    mem_random();
    foreach (scales[a])
      foreach (shifts[b])
        for (int d = 0; d < 3; d++) begin
          int unsigned sc = (a == 3) ? $urandom_range(3, 65534) : scales[a];
          int unsigned sh = (b == 2) ? $urandom_range(2, 29)    : shifts[b];
          sa_data_e    dm = (d == 0) ? DATA_SMALL : (d == 1) ? DATA_EXTREME : DATA_MAX;
          if (!j.randomize() with { req == 1; scale == sc; shift == sh; data == dm;
                                    m <= 12; n <= 12; (dm == DATA_MAX) -> (k == 64); })
            `uvm_fatal("RAND", "job")
          run_job(j);
        end

    // INT32 output with ReLU on and off, extreme data
    for (int i = 0; i < 6; i++) begin
      sa_data_e dm = (i % 3 == 0) ? DATA_MAX : (i % 3 == 1) ? DATA_EXTREME : DATA_SMALL;
      if (!j.randomize() with { req == 0; relu == (i < 3); data == dm; (dm == DATA_MAX) -> (k == 64); })
        `uvm_fatal("RAND", "job")
      run_job(j);
    end

    // exact saturation edges: r = a x b with SCALE/2^SHIFT = 1 (1/0 and 2/1)
    for (int i = 0; i < 8; i++) begin
      if (!j.randomize() with { req == 1; relu == 0; k == 1; m >= 8; n >= 8; data == DATA_SAT;
                                (i % 2 == 0) -> (scale == 1 && shift == 0);
                                (i % 2 == 1) -> (scale == 2 && shift == 1); })
        `uvm_fatal("RAND", "job")
      run_job(j);
    end

    foreach (must[i])
      if (!env.sb.corners.exists(must[i]))
        `uvm_error("QUANT", {"output-stage corner never checked: ", must[i]})
  endtask
endclass
