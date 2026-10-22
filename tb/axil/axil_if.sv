// AXI4-Lite interface for the SA-GEMM CSR port: 32-bit address and data, no PROT signals.
// Clocking blocks remove race conditions between the testbench and the DUT:
//   drv_cb drives 1 ns after the clock edge and samples just before it (#1step);
//   mon_cb only samples.
// The protocol assertions report through uvm_report_error so a failure fails the test.
interface axil_if (input logic clk, input logic rst_n);
  import uvm_pkg::*;

  logic [31:0] awaddr;
  logic        awvalid, awready;
  logic [31:0] wdata;
  logic [3:0]  wstrb;
  logic        wvalid, wready;
  logic [1:0]  bresp;
  logic        bvalid, bready;
  logic [31:0] araddr;
  logic        arvalid, arready;
  logic [31:0] rdata;
  logic [1:0]  rresp;
  logic        rvalid, rready;

  clocking drv_cb @(posedge clk);
    default input #1step output #1;
    output awaddr, awvalid, wdata, wstrb, wvalid, bready, araddr, arvalid, rready;
    input  awready, wready, bresp, bvalid, arready, rdata, rresp, rvalid;
  endclocking

  clocking mon_cb @(posedge clk);
    default input #1step;
    input awaddr, awvalid, awready, wdata, wstrb, wvalid, wready, bresp, bvalid, bready,
          araddr, arvalid, arready, rdata, rresp, rvalid, rready;
  endclocking

  // ------------------------------------------------------------ protocol assertions
  // VALID must stay high until READY (all five channels).
  property p_hold(logic v, logic r);
    @(posedge clk) disable iff (!rst_n) (v && !r) |=> v;
  endproperty
  // Payload must not change while VALID is waiting for READY.
  property p_stable(logic v, logic r, logic [35:0] d);
    @(posedge clk) disable iff (!rst_n) (v && !r) |=> $stable(d);
  endproperty

  a_aw_hold:   assert property (p_hold(awvalid, awready))     else uvm_report_error("AXIL_SVA", "AWVALID dropped before AWREADY");
  a_w_hold:    assert property (p_hold(wvalid,  wready))      else uvm_report_error("AXIL_SVA", "WVALID dropped before WREADY");
  a_b_hold:    assert property (p_hold(bvalid,  bready))      else uvm_report_error("AXIL_SVA", "BVALID dropped before BREADY");
  a_ar_hold:   assert property (p_hold(arvalid, arready))     else uvm_report_error("AXIL_SVA", "ARVALID dropped before ARREADY");
  a_r_hold:    assert property (p_hold(rvalid,  rready))      else uvm_report_error("AXIL_SVA", "RVALID dropped before RREADY");

  a_aw_stable: assert property (p_stable(awvalid, awready, 36'(awaddr)))      else uvm_report_error("AXIL_SVA", "AWADDR changed while waiting");
  a_w_stable:  assert property (p_stable(wvalid,  wready,  {wstrb, wdata}))   else uvm_report_error("AXIL_SVA", "WDATA/WSTRB changed while waiting");
  a_b_stable:  assert property (p_stable(bvalid,  bready,  36'(bresp)))       else uvm_report_error("AXIL_SVA", "BRESP changed while waiting");
  a_ar_stable: assert property (p_stable(arvalid, arready, 36'(araddr)))      else uvm_report_error("AXIL_SVA", "ARADDR changed while waiting");
  a_r_stable:  assert property (p_stable(rvalid,  rready,  {rresp, 2'b0, rdata})) else uvm_report_error("AXIL_SVA", "RDATA/RRESP changed while waiting");

  // During reset nobody may present a transfer.
  a_reset_quiet: assert property (@(posedge clk) !rst_n |-> !(awvalid || wvalid || arvalid || bvalid || rvalid))
    else uvm_report_error("AXIL_SVA", "a VALID is high during reset");

  // Handshake signals must never be X/Z outside reset.
  a_no_x: assert property (@(posedge clk) disable iff (!rst_n)
                           !$isunknown({awvalid, awready, wvalid, wready, bvalid, bready,
                                        arvalid, arready, rvalid, rready}))
    else uvm_report_error("AXIL_SVA", "X/Z on a VALID/READY signal");
endinterface
