// Designer smoke test for sa_outq: compares against the spec §7 formula in 64-bit arithmetic.
module tb_sa_outq;
  logic signed [31:0] acc;
  logic               req_en, relu_en;
  logic [4:0]         shift;
  logic [15:0]        scale;
  logic [31:0]        out32;
  logic [7:0]         out8;

  sa_outq dut (.*);

  int errors = 0;
  int checks = 0;

  function automatic void model(input longint a, input bit req, input bit relu, input int sh,
                                input longint sc, output longint e32, output longint e8);
    longint p, r;
    e32 = (relu && a < 0) ? 0 : a;
    p   = a * sc;
    r   = (sh == 0) ? p : ((p + (64'sd1 <<< (sh - 1))) >>> sh);
    if (relu && r < 0) r = 0;
    e8  = (r > 127) ? 127 : (r < -128) ? -128 : r;
  endfunction

  task automatic check(longint a, bit req, bit relu, int sh, longint sc);
    longint e32, e8;
    acc = a; req_en = req; relu_en = relu; shift = sh; scale = sc;
    #1;
    model(a, req, relu, sh, sc, e32, e8);
    checks++;
    if (!req && out32 !== 32'(e32)) begin
      errors++;
      $error("INT32 acc=%0d relu=%0b: dut=%0d exp=%0d", a, relu, $signed(out32), e32);
    end
    if (req && longint'($signed(out8)) != e8) begin
      errors++;
      $error("INT8 acc=%0d scale=%0d shift=%0d relu=%0b: dut=%0d exp=%0d",
             a, sc, sh, relu, $signed(out8), e8);
    end
  endtask

  initial begin
    // spec §7 examples (SCALE=1, SHIFT=1)
    check(3, 1, 0, 1, 1);
    check(-3, 1, 0, 1, 1);
    check(-4, 1, 0, 1, 1);

    // directed corners: zero/extreme acc, scale and shift edges, ties, ReLU
    begin
      static longint acc_l[]   = '{0, 1, -1, 127, 128, -128, -129, 1048576, -1048576,
                                   2147483647, -64'sd2147483648};
      static longint scale_l[] = '{0, 1, 2, 255, 32768, 65535};
      static int     shift_l[] = '{0, 1, 7, 15, 16, 30, 31};
      foreach (acc_l[a]) foreach (scale_l[s]) foreach (shift_l[h])
        for (int m = 0; m < 4; m++)
          check(acc_l[a], m[0], m[1], shift_l[h], scale_l[s]);
    end

    // random, mostly in the reachable |acc| <= 2^20 range
    repeat (20000) begin
      longint a;
      a = ($urandom_range(0, 9) == 0) ? longint'($signed($urandom))
                                      : longint'($urandom_range(0, 2097152)) - 1048576;
      check(a, $urandom_range(0, 1), $urandom_range(0, 1), $urandom_range(0, 31),
            $urandom_range(0, 65535));
    end

    if (errors == 0) $display("*** OUTQ SMOKE PASSED: %0d checks ***", checks);
    else             $display("*** OUTQ SMOKE FAILED: %0d errors in %0d checks ***", errors, checks);
    $finish;
  end
endmodule
