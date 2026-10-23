// Full-chip testbench top: sa_top with the AXI4-Lite CPU interface and the AXI4 memory interface.
// ARRAY_N (PE array size) comes from +define+ARRAY_N=<n> (files_top8.f builds 8); default 4.
`ifndef ARRAY_N
  `define ARRAY_N 4
`endif

module tb_top;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import sa_top_tb_pkg::*;

  localparam int ARRAY_N = `ARRAY_N;

  logic clk = 1'b0;
  logic por_n;                           // power-on reset
  wire  rst_n;
  always #5 clk = ~clk;                  // 100 MHz

  initial begin
    por_n = 1'b0;
    #47 por_n = 1'b1;
  end

  axil_if   axil (.clk(clk), .rst_n(rst_n));
  axi_if    axi  (.clk(clk), .rst_n(rst_n));
  sa_sys_if sys  (.clk(clk), .rst_n(rst_n));

  // Tests can also assert the (asynchronous) reset in the middle of a job through sys.rst_req.
  assign rst_n = por_n && !sys.rst_req;

  // White-box probes (see sa_sys_if): the controller's BUSY and state.
  assign sys.busy       = dut.busy;
  assign sys.ctrl_state = dut.u_ctrl.state;

  sa_top #(.ARRAY_N(ARRAY_N)) dut (
    .clk            (clk),
    .rst_n          (rst_n),
    .s_axil_awaddr  (axil.awaddr),  .s_axil_awvalid (axil.awvalid), .s_axil_awready (axil.awready),
    .s_axil_wdata   (axil.wdata),   .s_axil_wstrb   (axil.wstrb),   .s_axil_wvalid  (axil.wvalid),
    .s_axil_wready  (axil.wready),  .s_axil_bresp   (axil.bresp),   .s_axil_bvalid  (axil.bvalid),
    .s_axil_bready  (axil.bready),  .s_axil_araddr  (axil.araddr),  .s_axil_arvalid (axil.arvalid),
    .s_axil_arready (axil.arready), .s_axil_rdata   (axil.rdata),   .s_axil_rresp   (axil.rresp),
    .s_axil_rvalid  (axil.rvalid),  .s_axil_rready  (axil.rready),

    .m_axi_awid     (axi.awid),     .m_axi_awaddr   (axi.awaddr),   .m_axi_awlen    (axi.awlen),
    .m_axi_awsize   (axi.awsize),   .m_axi_awburst  (axi.awburst),  .m_axi_awvalid  (axi.awvalid),
    .m_axi_awready  (axi.awready),  .m_axi_wdata    (axi.wdata),    .m_axi_wstrb    (axi.wstrb),
    .m_axi_wlast    (axi.wlast),    .m_axi_wvalid   (axi.wvalid),   .m_axi_wready   (axi.wready),
    .m_axi_bid      (axi.bid),      .m_axi_bresp    (axi.bresp),    .m_axi_bvalid   (axi.bvalid),
    .m_axi_bready   (axi.bready),   .m_axi_arid     (axi.arid),     .m_axi_araddr   (axi.araddr),
    .m_axi_arlen    (axi.arlen),    .m_axi_arsize   (axi.arsize),   .m_axi_arburst  (axi.arburst),
    .m_axi_arvalid  (axi.arvalid),  .m_axi_arready  (axi.arready),  .m_axi_rid      (axi.rid),
    .m_axi_rdata    (axi.rdata),    .m_axi_rresp    (axi.rresp),    .m_axi_rlast    (axi.rlast),
    .m_axi_rvalid   (axi.rvalid),   .m_axi_rready   (axi.rready),

    .irq            (sys.irq)
  );

  initial begin
    uvm_config_db#(virtual axil_if)::set(null, "uvm_test_top*", "vif", axil);
    uvm_config_db#(virtual axi_if)::set(null, "uvm_test_top*", "axi_vif", axi);
    uvm_config_db#(virtual sa_sys_if)::set(null, "uvm_test_top*", "sys_vif", sys);
    uvm_config_db#(int unsigned)::set(null, "uvm_test_top*", "array_n", ARRAY_N);
    run_test();
  end
endmodule
