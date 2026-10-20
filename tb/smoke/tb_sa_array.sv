// Designer smoke test for sa_array (not the DV environment).
// Feeds skewed A rows / B columns, optionally with random stalls, and compares against a
// software matrix multiply.
module tb_sa_array;
  localparam int N      = 4;
  localparam int DATA_W = 8;
  localparam int ACC_W  = 32;
  localparam int KMAX   = 64;

  logic clk = 0, rst_n = 0, clear = 0, en = 0;
  logic signed [DATA_W-1:0] a_west  [N];
  logic signed [DATA_W-1:0] b_north [N];
  logic signed [ACC_W-1:0]  c_out   [N][N];

  sa_array #(.N(N), .DATA_W(DATA_W), .ACC_W(ACC_W)) dut (.*);

  always #5 clk = ~clk;

  logic signed [DATA_W-1:0] A [N][KMAX];
  logic signed [DATA_W-1:0] B [KMAX][N];
  int errors = 0;
  int cases  = 0;

  typedef enum {RANDOM, ALL_MIN, MIN_TIMES_MAX} fill_e;

  task automatic fill(int K, fill_e kind);
    for (int i = 0; i < N; i++)
      for (int k = 0; k < K; k++) begin
        case (kind)
          RANDOM:        begin A[i][k] = $urandom_range(0, 255); B[k][i] = $urandom_range(0, 255); end
          ALL_MIN:       begin A[i][k] = -128;                   B[k][i] = -128;                   end
          MIN_TIMES_MAX: begin A[i][k] = -128;                   B[k][i] = 127;                    end
        endcase
      end
  endtask

  task automatic run_case(int K, fill_e kind, bit stalls);
    int t;
    fill(K, kind);

    @(negedge clk); clear = 1; en = 0;
    @(negedge clk); clear = 0;

    t = 0;
    while (t < K + 2*N - 2) begin
      @(negedge clk);
      if (stalls && $urandom_range(0, 3) == 0) begin
        en = 0;                       // stall this cycle; inputs are don't-care
        continue;
      end
      en = 1;
      for (int i = 0; i < N; i++) a_west[i]  = (t - i >= 0 && t - i < K) ? A[i][t - i] : '0;
      for (int j = 0; j < N; j++) b_north[j] = (t - j >= 0 && t - j < K) ? B[t - j][j] : '0;
      t++;
    end
    @(negedge clk); en = 0;

    for (int i = 0; i < N; i++)
      for (int j = 0; j < N; j++) begin
        int exp_c = 0;
        for (int k = 0; k < K; k++) exp_c += int'(A[i][k]) * int'(B[k][j]);
        if (c_out[i][j] !== exp_c) begin
          errors++;
          $error("K=%0d %s stalls=%0b: C[%0d][%0d] dut=%0d exp=%0d",
                 K, kind.name(), stalls, i, j, c_out[i][j], exp_c);
        end
      end
    cases++;
  endtask

  initial begin
    foreach (a_west[i])  a_west[i]  = '0;
    foreach (b_north[j]) b_north[j] = '0;
    repeat (2) @(negedge clk);
    rst_n = 1;

    // directed: dimension edges and extreme values, with and without stalls
    begin
      static int k_list[] = '{1, 2, N, 17, KMAX};
      foreach (k_list[x])
        for (int kind = RANDOM; kind <= MIN_TIMES_MAX; kind++)
          for (int s = 0; s <= 1; s++)
            run_case(k_list[x], fill_e'(kind), s[0]);
    end

    // random K with random stalls
    repeat (50) run_case($urandom_range(1, KMAX), RANDOM, 1'b1);

    if (errors == 0) $display("*** SMOKE PASSED: %0d cases ***", cases);
    else             $display("*** SMOKE FAILED: %0d errors in %0d cases ***", errors, cases);
    $finish;
  end
endmodule
