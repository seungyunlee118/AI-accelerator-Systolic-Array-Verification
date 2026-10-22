// 4 KB boundaries (vplan F-DMA-02). Every matrix starts a few words before the end of a 4 KB
// page and its stride is just under or over 4 KB, so most A rows, B rows and C rows cross a page
// boundary at a different offset. The DMA must split those bursts (SVA a_ar_4k / a_aw_4k) and
// still read every needed byte (DMA checker) and write exactly the C bytes (scoreboard).
class dma_4k_test extends sa_top_base_test;
  `uvm_component_utils(dma_4k_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // A row of 'len' bytes at 'a' crosses a 4 KB boundary.
  function bit crosses(bit [31:0] a, int unsigned len);
    return (a[11:0] + len) > 32'h1000;
  endfunction

  virtual task body();
    sa_job       j = sa_job::type_id::create("j");
    int unsigned n_jobs = 16, rows = 0, split = 0;
    void'($value$plusargs("JOBS=%d", n_jobs));

    j.c_strides.constraint_mode(0);
    j.c_bases.constraint_mode(0);
    repeat (n_jobs) begin
      mem_random();
      if (!j.randomize() with { k >= 9; n >= 9; }) `uvm_fatal("RAND", "job")
      // the last 1..7 words of a page; strides of 4 KB -/+ up to 7 words
      j.a_base   = 32'h0010_1000 - 8 * $urandom_range(1, 7);
      j.b_base   = 32'h0020_1000 - 8 * $urandom_range(1, 7);
      j.c_base   = 32'h0030_1000 - 8 * $urandom_range(1, 7);
      j.a_stride = 4096 - 56 + 8 * $urandom_range(0, 14);
      j.b_stride = 4096 - 56 + 8 * $urandom_range(0, 14);
      j.c_stride = 4096 - 56 + 8 * $urandom_range(0, 14);
      for (int r = 0; r < j.m; r++) begin rows++; split += crosses(j.a_base + r * j.a_stride, j.k); end
      for (int r = 0; r < j.k; r++) begin rows++; split += crosses(j.b_base + r * j.b_stride, j.n); end
      for (int r = 0; r < j.m; r++) begin rows++; split += crosses(j.c_base + r * j.c_stride, j.e() * j.n); end
      run_job(j);
    end
    `uvm_info("DMA_4K", $sformatf("%0d of %0d rows crossed a 4 KB boundary", split, rows), UVM_NONE)
    if (split == 0) `uvm_error("DMA_4K", "no row crossed a 4 KB boundary")
  endtask
endclass
