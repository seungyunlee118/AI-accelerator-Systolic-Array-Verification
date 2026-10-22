// Strides (vplan F-DP-03, F-DMA-03). Each matrix gets its own stride kind per job:
//   EXACT    rows packed (stride = row length rounded up to 8 bytes)
//   GAP      1..8 unused words between rows
//   LARGE    2-4 KB (A, B) or 0.5-1 KB (C), so rows sit in different 4 KB pages
//   OVERLAP  A/B only: stride smaller than the row, so rows share bytes (legal, spec v0.3)
//   ZERO     A/B only: stride 0, every row is the same row
// C may not overlap (C_STRIDE < E*N is BAD_ADDR). The matrices live 1 MB apart so the largest
// strides cannot collide. With overlapping rows the unique-row-index byte is overwritten by the
// next row; the expected result is still exact because the scoreboard predicts from memory.
class gemm_stride_test extends sa_top_base_test;
  `uvm_component_utils(gemm_stride_test)

  typedef enum {EXACT, GAP, LARGE, OVERLAP, ZERO} stride_e;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function int unsigned pick(stride_e kind, int unsigned row_bytes, bit is_c);
    int unsigned packed_len = 8 * ((row_bytes + 7) / 8);
    case (kind)
      GAP:     return packed_len + 8 * $urandom_range(1, 8);
      LARGE:   return is_c ? 8 * $urandom_range(64, 128) : 8 * $urandom_range(256, 512);
      OVERLAP: return 8 * $urandom_range(0, (packed_len / 8) - 1);
      ZERO:    return 0;
      default: return packed_len;
    endcase
  endfunction

  virtual task body();
    sa_job       j = sa_job::type_id::create("j");
    int unsigned n_jobs = 30;
    int unsigned seen[string];
    void'($value$plusargs("JOBS=%d", n_jobs));

    j.c_strides.constraint_mode(0);
    j.c_bases.constraint_mode(0);
    for (int i = 0; i < n_jobs; i++) begin
      stride_e ka = stride_e'($urandom_range(0, 4));
      stride_e kb = stride_e'($urandom_range(0, 4));
      stride_e kc = stride_e'($urandom_range(0, 2));
      mem_random();
      if (!j.randomize() with {
            a_base inside {[32'h0010_0000 : 32'h0010_0FF8]};  a_base[2:0] == 0;
            b_base inside {[32'h0020_0000 : 32'h0020_0FF8]};  b_base[2:0] == 0;
            c_base inside {[32'h0030_0000 : 32'h0030_0FF8]};  c_base[2:0] == 0; })
        `uvm_fatal("RAND", "job")
      j.a_stride = pick(ka, j.k, 0);
      j.b_stride = pick(kb, j.n, 0);
      j.c_stride = pick(kc, j.e() * j.n, 1);
      seen[{"A_", ka.name()}] = 1;  seen[{"B_", kb.name()}] = 1;  seen[{"C_", kc.name()}] = 1;
      `uvm_info("STRIDE", $sformatf("A %s, B %s, C %s: %s", ka.name(), kb.name(), kc.name(), j.convert2string()), UVM_LOW)
      run_job(j);
    end
    begin
      string s = "stride kinds used:";
      foreach (seen[k]) s = {s, " ", k};
      `uvm_info("STRIDE", s, UVM_NONE)
    end
  endtask
endclass
