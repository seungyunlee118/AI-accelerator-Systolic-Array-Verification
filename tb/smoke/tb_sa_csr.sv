// Designer smoke test for sa_csr: directed AXI4-Lite accesses with AW/W ordering variations.
module tb_sa_csr;
  logic        clk = 0, rst_n = 0;
  logic [31:0] s_axil_awaddr = '0, s_axil_wdata = '0, s_axil_araddr = '0;
  logic        s_axil_awvalid = 0, s_axil_wvalid = 0, s_axil_bready = 0;
  logic        s_axil_arvalid = 0, s_axil_rready = 0;
  logic [3:0]  s_axil_wstrb = '0;
  logic        s_axil_awready, s_axil_wready, s_axil_bvalid, s_axil_arready, s_axil_rvalid;
  logic [1:0]  s_axil_bresp, s_axil_rresp;
  logic [31:0] s_axil_rdata;

  logic        start, busy = 0, evt_done = 0, evt_err = 0, irq;
  logic [3:0]  err_code = '0;
  logic [31:0] cycles = '0;
  logic [6:0]  dim_m, dim_n, dim_k;
  logic [31:0] a_base, b_base, c_base;
  logic [15:0] a_stride, b_stride, c_stride, scale;
  logic        req_en, relu_en;
  logic [4:0]  shift;

  sa_csr dut (.*);

  always #5 clk = ~clk;

  int errors = 0;
  int start_pulses = 0;
  always @(posedge clk) if (start) start_pulses++;

  localparam int AW_FIRST = 1, W_FIRST = 2;

  // mode 0: AW and W together, AW_FIRST: W two cycles later, W_FIRST: AW two cycles later
  task automatic axil_write(logic [31:0] addr, logic [31:0] data, logic [3:0] strb, int mode,
                            output logic [1:0] resp);
    fork
      begin
        if (mode == W_FIRST) repeat (2) @(negedge clk);
        @(negedge clk); s_axil_awaddr = addr; s_axil_awvalid = 1;
        @(posedge clk); while (!s_axil_awready) @(posedge clk);
        @(negedge clk); s_axil_awvalid = 0;
      end
      begin
        if (mode == AW_FIRST) repeat (2) @(negedge clk);
        @(negedge clk); s_axil_wdata = data; s_axil_wstrb = strb; s_axil_wvalid = 1;
        @(posedge clk); while (!s_axil_wready) @(posedge clk);
        @(negedge clk); s_axil_wvalid = 0;
      end
    join
    s_axil_bready = 1;
    @(posedge clk); while (!s_axil_bvalid) @(posedge clk);
    resp = s_axil_bresp;
    @(negedge clk); s_axil_bready = 0;
  endtask

  task automatic axil_read(logic [31:0] addr, output logic [31:0] data, output logic [1:0] resp);
    @(negedge clk); s_axil_araddr = addr; s_axil_arvalid = 1; s_axil_rready = 1;
    @(posedge clk); while (!s_axil_arready) @(posedge clk);
    @(negedge clk); s_axil_arvalid = 0;
    @(posedge clk); while (!s_axil_rvalid) @(posedge clk);
    data = s_axil_rdata; resp = s_axil_rresp;
    @(negedge clk); s_axil_rready = 0;
  endtask

  task automatic expect_read(string what, logic [31:0] addr, logic [31:0] exp_d, logic [1:0] exp_r);
    logic [31:0] d; logic [1:0] r;
    axil_read(addr, d, r);
    if (d !== exp_d || r !== exp_r) begin
      errors++;
      $error("%s: read 0x%02h got data=0x%08h resp=%0d, exp data=0x%08h resp=%0d",
             what, addr, d, r, exp_d, exp_r);
    end
  endtask

  task automatic expect_write(string what, logic [31:0] addr, logic [31:0] data, logic [3:0] strb,
                              int mode, logic [1:0] exp_r);
    logic [1:0] r;
    axil_write(addr, data, strb, mode, r);
    if (r !== exp_r) begin
      errors++;
      $error("%s: write 0x%02h resp=%0d exp=%0d", what, addr, r, exp_r);
    end
  endtask

  typedef struct { logic [7:0] addr; logic [31:0] mask; } rw_reg_t;
  rw_reg_t rw_regs[] = '{
    '{8'h08, 32'h0000_0003}, '{8'h10, 32'h007F_7F7F}, '{8'h14, 32'hFFFF_FFFF},
    '{8'h18, 32'h0000_FFFF}, '{8'h1C, 32'hFFFF_FFFF}, '{8'h20, 32'h0000_FFFF},
    '{8'h24, 32'hFFFF_FFFF}, '{8'h28, 32'h0000_FFFF}, '{8'h34, 32'h0000_1F03},
    '{8'h38, 32'h0000_FFFF}};

  initial begin
    repeat (2) @(negedge clk);
    rst_n = 1;

    // 1. reset values
    foreach (rw_regs[i]) expect_read("reset", rw_regs[i].addr, '0, 2'b00);
    expect_read("reset STATUS",  8'h04, '0, 2'b00);
    expect_read("reset IRQ_ST",  8'h0C, '0, 2'b00);
    expect_read("VERSION",       8'h30, 32'h5341_0002, 2'b00);

    // 2. RW registers, every AW/W ordering
    for (int mode = 0; mode < 3; mode++)
      foreach (rw_regs[i]) begin
        logic [31:0] v;
        v = $urandom;   // separate from the declaration: a static initializer runs only once
        expect_write("rw", rw_regs[i].addr, v, 4'hF, mode, 2'b00);
        expect_read ("rw", rw_regs[i].addr, v & rw_regs[i].mask, 2'b00);
      end

    // 3. byte strobes: only lanes 0 and 2 change
    expect_write("strb init", 8'h14, 32'h1111_1111, 4'hF, 0, 2'b00);
    expect_write("strb",      8'h14, 32'hAABB_CCDD, 4'b0101, 0, 2'b00);
    expect_read ("strb",      8'h14, 32'h11BB_11DD, 2'b00);

    // 4. unmapped offsets: SLVERR, reads return 0
    expect_write("unmapped", 8'h3C, 32'hFFFF_FFFF, 4'hF, 0, 2'b10);
    expect_read ("unmapped", 8'h3C, '0, 2'b10);
    expect_read ("unmapped", 8'hFC, '0, 2'b10);

    // 5. address decode ignores [31:8] and [1:0]
    expect_write("alias", 32'h0000_0114, 32'h0000_1234, 4'hF, 0, 2'b00);
    expect_read ("alias", 8'h14,          32'h0000_1234, 2'b00);
    expect_read ("alias", 32'hABCD_0017,  32'h0000_1234, 2'b00);

    // 6. RO registers: write OKAY, no effect
    expect_write("ro", 8'h30, 32'h0, 4'hF, 0, 2'b00);
    expect_read ("ro", 8'h30, 32'h5341_0002, 2'b00);
    busy = 1; err_code = 4'h3; cycles = 32'd777;
    expect_read ("STATUS", 8'h04, 32'h0000_0031, 2'b00);
    expect_read ("CYCLES", 8'h2C, 32'd777, 2'b00);
    busy = 0; err_code = 0;

    // 7. START pulse: only with wstrb[0] and wdata[0]; CTRL reads 0
    start_pulses = 0;
    expect_write("start", 8'h00, 32'h1, 4'h1, 0, 2'b00);
    expect_write("start no strb", 8'h00, 32'h1, 4'hE, 0, 2'b00);
    expect_write("start data0",   8'h00, 32'h0, 4'hF, 0, 2'b00);
    repeat (2) @(negedge clk);
    if (start_pulses != 1) begin errors++; $error("start pulses=%0d exp=1", start_pulses); end
    expect_read("CTRL", 8'h00, '0, 2'b00);

    // 8. IRQ: sticky status, enable gating, W1C
    expect_write("irq_en off", 8'h08, 32'h0, 4'hF, 0, 2'b00);
    @(negedge clk); evt_done = 1; @(negedge clk); evt_done = 0;
    expect_read("irq done", 8'h0C, 32'h1, 2'b00);
    if (irq !== 1'b0) begin errors++; $error("irq set while disabled"); end
    expect_write("irq_en", 8'h08, 32'h3, 4'hF, 0, 2'b00);
    if (irq !== 1'b1) begin errors++; $error("irq not set when enabled"); end
    expect_write("w1c", 8'h0C, 32'h1, 4'hF, 0, 2'b00);
    expect_read ("w1c", 8'h0C, 32'h0, 2'b00);
    if (irq !== 1'b0) begin errors++; $error("irq still set after W1C"); end

    // 9. same-cycle set and W1C clear: the set wins
    @(negedge clk); evt_err = 1; @(negedge clk); evt_err = 0;
    fork
      expect_write("w1c race", 8'h0C, 32'h2, 4'hF, 0, 2'b00);
      begin
        wait (dut.do_write === 1'b1);
        evt_err = 1;
        @(posedge clk);          // the edge where the W1C clear is applied
        @(negedge clk) evt_err = 0;
      end
    join
    expect_read("w1c race", 8'h0C, 32'h2, 2'b00);

    // 10. field mapping to the core
    expect_write("dims", 8'h10, 32'h0040_2010, 4'hF, 0, 2'b00);
    if (dim_m !== 7'h10 || dim_n !== 7'h20 || dim_k !== 7'h40) begin
      errors++; $error("dims fields m=%0h n=%0h k=%0h", dim_m, dim_n, dim_k);
    end
    expect_write("qcfg", 8'h34, 32'h0000_1F03, 4'hF, 0, 2'b00);
    if (!req_en || !relu_en || shift !== 5'd31) begin errors++; $error("qcfg fields"); end

    if (errors == 0) $display("*** CSR SMOKE PASSED ***");
    else             $display("*** CSR SMOKE FAILED: %0d errors ***", errors);
    $finish;
  end
endmodule
