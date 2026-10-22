// One GEMM job: everything software programs before START. Randomizing it with the default
// constraints gives a legal job; tests turn constraints off or override fields for corner and
// error cases.
class sa_job extends uvm_object;
  `uvm_object_utils(sa_job)

  rand int unsigned m, n, k;
  rand bit          req, relu;
  rand int unsigned shift, scale;
  rand bit [31:0]   a_base, b_base, c_base;
  rand int unsigned a_stride, b_stride, c_stride;
  rand int unsigned a_gap, b_gap, c_gap;          // extra 8-byte words between rows

  constraint c_dims  { m inside {[1:64]};  n inside {[1:64]};  k inside {[1:64]}; }
  constraint c_quant { shift inside {[0:31]};  scale inside {[0:65535]}; }
  constraint c_gaps  { a_gap inside {[0:2]};  b_gap inside {[0:2]};  c_gap inside {[0:2]}; }
  constraint c_strides {
    a_stride == 8 * ((k + 7) / 8 + a_gap);
    b_stride == 8 * ((n + 7) / 8 + b_gap);
    c_stride == 8 * (((req ? n : 4 * n) + 7) / 8 + c_gap);
  }
  // A, B and C live in separate regions; the low 12 bits are random so rows often cross 4 KB.
  constraint c_bases {
    a_base inside {[32'h0001_0000 : 32'h0001_0FF8]};  a_base[2:0] == 3'b0;
    b_base inside {[32'h0004_0000 : 32'h0004_0FF8]};  b_base[2:0] == 3'b0;
    c_base inside {[32'h0008_0000 : 32'h0008_0FF8]};  c_base[2:0] == 3'b0;
  }
  constraint c_order { solve m, n, k, req, a_gap, b_gap, c_gap before a_stride, b_stride, c_stride; }

  function new(string name = "sa_job");
    super.new(name);
  endfunction

  function int unsigned e();                       // bytes per C element
    return req ? 1 : 4;
  endfunction

  // Error code the configuration check must report (spec §8); 0 if the job is legal.
  function bit [3:0] cfg_err();
    if (m == 0 || m > 64 || n == 0 || n > 64 || k == 0 || k > 64) return 4'd1;
    if (a_base[2:0] != 0 || b_base[2:0] != 0 || c_base[2:0] != 0 ||
        a_stride % 8 != 0 || b_stride % 8 != 0 || c_stride % 8 != 0 ||
        c_stride < e() * n) return 4'd2;
    return 4'd0;
  endfunction

  virtual function string convert2string();
    return $sformatf("M=%0d N=%0d K=%0d %s relu=%0b shift=%0d scale=%0d A=%08h/%0d B=%08h/%0d C=%08h/%0d",
                     m, n, k, req ? "INT8" : "INT32", relu, shift, scale,
                     a_base, a_stride, b_base, b_stride, c_base, c_stride);
  endfunction
endclass
