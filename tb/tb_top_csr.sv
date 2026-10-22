// Block-level testbench top for the CSR block (sa_csr) alone.
// The core-side inputs (busy, error code, events, cycle count) come from csr_core_if, which
// tests drive in place of the controller.
module tb_top_csr;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import sa_tb_pkg::*;

  logic clk = 1'b0;
  logic rst_n;
  always #5 clk = ~clk;            // 100 MHz

  initial begin                    // reset for the first few cycles, released between edges
    rst_n = 1'b0;
    #47 rst_n = 1'b1;
  end

  axil_if     axil (.clk(clk), .rst_n(rst_n));
  csr_core_if core (.clk(clk), .rst_n(rst_n));   // stands in for the controller

  // For csr_irq_test: raise an event in exactly the cycle an IRQ_STATUS write takes effect.
  wire race_hit = dut.do_write && (dut.aw_addr_q == 8'h0C);
  wire evt_done = core.evt_done | (core.race_done & race_hit);
  wire evt_err  = core.evt_err  | (core.race_err  & race_hit);

  // coverage probes (CG-01r)
  assign core.w1c_commit   = race_hit;
  assign core.w1c_clr      = dut.w_data_q[1:0] & {2{dut.w_strb_q[0]}};
  assign core.dut_evt_done = evt_done;
  assign core.dut_evt_err  = evt_err;

  // core-side outputs of the CSR block that only the full chip uses
  logic        req_en, relu_en;
  logic [6:0]  dim_m, dim_n, dim_k;
  logic [31:0] a_base, b_base, c_base;
  logic [15:0] a_stride, b_stride, c_stride, scale;
  logic [4:0]  shift;

  sa_csr dut (
    .clk            (clk),
    .rst_n          (rst_n),
    .s_axil_awaddr  (axil.awaddr),
    .s_axil_awvalid (axil.awvalid),
    .s_axil_awready (axil.awready),
    .s_axil_wdata   (axil.wdata),
    .s_axil_wstrb   (axil.wstrb),
    .s_axil_wvalid  (axil.wvalid),
    .s_axil_wready  (axil.wready),
    .s_axil_bresp   (axil.bresp),
    .s_axil_bvalid  (axil.bvalid),
    .s_axil_bready  (axil.bready),
    .s_axil_araddr  (axil.araddr),
    .s_axil_arvalid (axil.arvalid),
    .s_axil_arready (axil.arready),
    .s_axil_rdata   (axil.rdata),
    .s_axil_rresp   (axil.rresp),
    .s_axil_rvalid  (axil.rvalid),
    .s_axil_rready  (axil.rready),
    .start          (core.start),
    .busy           (core.busy),
    .err_code       (core.err_code),
    .evt_done       (evt_done),
    .evt_err        (evt_err),
    .cycles         (core.cycles),
    .dim_m          (dim_m),
    .dim_n          (dim_n),
    .dim_k          (dim_k),
    .a_base         (a_base),
    .a_stride       (a_stride),
    .b_base         (b_base),
    .b_stride       (b_stride),
    .c_base         (c_base),
    .c_stride       (c_stride),
    .req_en         (req_en),
    .relu_en        (relu_en),
    .shift          (shift),
    .scale          (scale),
    .irq            (core.irq)
  );

  initial begin
    uvm_config_db#(virtual axil_if)::set(null, "uvm_test_top*", "vif", axil);
    uvm_config_db#(virtual csr_core_if)::set(null, "uvm_test_top*", "core_vif", core);
    run_test();
  end
endmodule
