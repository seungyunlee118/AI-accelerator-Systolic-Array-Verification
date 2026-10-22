// AXI4 interface between the SA-GEMM DMA (master) and the testbench memory (slave).
// 32-bit address, 64-bit data, 4-bit IDs. slv_cb is used by the memory responder (it drives
// READY on AR/AW/W and the B/R channels); mon_cb only samples.
//
// The assertions check the AXI4 protocol on both sides and the DMA rules of spec §6.1
// (vplan CHK-05, CHK-06, CHK-11). They report through uvm_report_error.
interface axi_if (input logic clk, input logic rst_n);
  import uvm_pkg::*;

  logic [3:0]  awid;   logic [31:0] awaddr; logic [7:0] awlen; logic [2:0] awsize; logic [1:0] awburst;
  logic        awvalid, awready;
  logic [63:0] wdata;  logic [7:0]  wstrb;  logic       wlast;
  logic        wvalid, wready;
  logic [3:0]  bid;    logic [1:0]  bresp;
  logic        bvalid, bready;
  logic [3:0]  arid;   logic [31:0] araddr; logic [7:0] arlen; logic [2:0] arsize; logic [1:0] arburst;
  logic        arvalid, arready;
  logic [3:0]  rid;    logic [63:0] rdata;  logic [1:0] rresp; logic       rlast;
  logic        rvalid, rready;

  clocking slv_cb @(posedge clk);
    default input #1step output #1;
    output awready, wready, bid, bresp, bvalid, arready, rid, rdata, rresp, rlast, rvalid;
    input  awid, awaddr, awlen, awsize, awburst, awvalid, wdata, wstrb, wlast, wvalid, bready,
           arid, araddr, arlen, arsize, arburst, arvalid, rready;
  endclocking

  clocking mon_cb @(posedge clk);
    default input #1step;
    input awid, awaddr, awlen, awsize, awburst, awvalid, awready, wdata, wstrb, wlast, wvalid, wready,
          bid, bresp, bvalid, bready, arid, araddr, arlen, arsize, arburst, arvalid, arready,
          rid, rdata, rresp, rlast, rvalid, rready;
  endclocking

  // ------------------------------------------------------------ AXI4 protocol (CHK-05)
  property p_hold(logic v, logic r);
    @(posedge clk) disable iff (!rst_n) (v && !r) |=> v;
  endproperty
  property p_stable(logic v, logic r, logic [79:0] d);
    @(posedge clk) disable iff (!rst_n) (v && !r) |=> $stable(d);
  endproperty

  a_aw_hold: assert property (p_hold(awvalid, awready)) else uvm_report_error("AXI_SVA", "AWVALID dropped before AWREADY");
  a_w_hold:  assert property (p_hold(wvalid,  wready))  else uvm_report_error("AXI_SVA", "WVALID dropped before WREADY");
  a_ar_hold: assert property (p_hold(arvalid, arready)) else uvm_report_error("AXI_SVA", "ARVALID dropped before ARREADY");
  a_b_hold:  assert property (p_hold(bvalid,  bready))  else uvm_report_error("AXI_SVA", "BVALID dropped before BREADY");
  a_r_hold:  assert property (p_hold(rvalid,  rready))  else uvm_report_error("AXI_SVA", "RVALID dropped before RREADY");

  a_aw_stable: assert property (p_stable(awvalid, awready, 80'({awid, awaddr, awlen, awsize, awburst})))
    else uvm_report_error("AXI_SVA", "AW payload changed while waiting");
  a_w_stable:  assert property (p_stable(wvalid, wready, 80'({wlast, wstrb, wdata})))
    else uvm_report_error("AXI_SVA", "W payload changed while waiting");
  a_ar_stable: assert property (p_stable(arvalid, arready, 80'({arid, araddr, arlen, arsize, arburst})))
    else uvm_report_error("AXI_SVA", "AR payload changed while waiting");
  a_r_stable:  assert property (p_stable(rvalid, rready, 80'({rid, rresp, rlast, rdata})))
    else uvm_report_error("AXI_SVA", "R payload changed while waiting");
  a_b_stable:  assert property (p_stable(bvalid, bready, 80'({bid, bresp})))
    else uvm_report_error("AXI_SVA", "B payload changed while waiting");

  a_no_x: assert property (@(posedge clk) disable iff (!rst_n)
                           !$isunknown({awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready}))
    else uvm_report_error("AXI_SVA", "X/Z on a VALID/READY signal");

  // ------------------------------------------------------------ burst shape (spec §6.1, CHK-05)
  a_ar_shape: assert property (@(posedge clk) disable iff (!rst_n)
      arvalid |-> (arsize == 3'd3 && arburst == 2'b01 && arlen <= 8'd7 && araddr[2:0] == 3'b0))
    else uvm_report_error("AXI_SVA", $sformatf("AR shape: addr=%h len=%0d size=%0d burst=%0d", araddr, arlen, arsize, arburst));
  a_aw_shape: assert property (@(posedge clk) disable iff (!rst_n)
      awvalid |-> (awsize == 3'd3 && awburst == 2'b01 && awlen <= 8'd7 && awaddr[2:0] == 3'b0 && awid == 4'd0))
    else uvm_report_error("AXI_SVA", $sformatf("AW shape: id=%0d addr=%h len=%0d size=%0d burst=%0d", awid, awaddr, awlen, awsize, awburst));
  a_ar_4k: assert property (@(posedge clk) disable iff (!rst_n)
      arvalid |-> (13'(araddr[11:0]) + 13'({arlen[3:0], 3'b000}) + 13'd8 <= 13'h1000))
    else uvm_report_error("AXI_SVA", $sformatf("read burst crosses 4 KB: addr=%h len=%0d", araddr, arlen));
  a_aw_4k: assert property (@(posedge clk) disable iff (!rst_n)
      awvalid |-> (13'(awaddr[11:0]) + 13'({awlen[3:0], 3'b000}) + 13'd8 <= 13'h1000))
    else uvm_report_error("AXI_SVA", $sformatf("write burst crosses 4 KB: addr=%h len=%0d", awaddr, awlen));

  // ------------------------------------------------------------ DMA rules (spec §6.1, CHK-06)
  logic [15:0] rd_inflight;      // ARIDs with a read burst in flight
  int          wr_outstanding;   // AWs accepted whose B has not arrived
  int          w_owed;           // AWs accepted whose WLAST has not been sent

  always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      rd_inflight    <= '0;
      wr_outstanding <= 0;
      w_owed         <= 0;
    end else begin
      if (arvalid && arready)          rd_inflight[arid] <= 1'b1;
      if (rvalid && rready && rlast)   rd_inflight[rid]  <= 1'b0;
      wr_outstanding <= wr_outstanding + int'(awvalid && awready) - int'(bvalid && bready);
      w_owed         <= w_owed + int'(awvalid && awready) - int'(wvalid && wready && wlast);
    end

  a_rd_ot_max: assert property (@(posedge clk) disable iff (!rst_n) $countones(rd_inflight) <= 4)
    else uvm_report_error("AXI_SVA", "more than 4 read bursts outstanding");
  a_arid_range: assert property (@(posedge clk) disable iff (!rst_n) arvalid |-> arid <= 4'd3)
    else uvm_report_error("AXI_SVA", $sformatf("ARID %0d out of range 0..3", arid));
  a_arid_unique: assert property (@(posedge clk) disable iff (!rst_n) (arvalid && arready) |-> !rd_inflight[arid])
    else uvm_report_error("AXI_SVA", $sformatf("ARID %0d reused while its burst is in flight", arid));
  a_r_known_id: assert property (@(posedge clk) disable iff (!rst_n) rvalid |-> rd_inflight[rid])
    else uvm_report_error("AXI_SVA", $sformatf("R beat for ID %0d with no burst in flight", rid));
  a_wr_one: assert property (@(posedge clk) disable iff (!rst_n) (awvalid && awready) |-> (wr_outstanding == 0))
    else uvm_report_error("AXI_SVA", "a second write burst issued before the first B response");
  a_w_after_aw: assert property (@(posedge clk) disable iff (!rst_n) wvalid |-> (w_owed > 0 || awvalid))
    else uvm_report_error("AXI_SVA", "WVALID before its AWVALID");

  // ------------------------------------------------------------ reset (CHK-11)
  a_reset_quiet: assert property (@(posedge clk) !rst_n |-> !(awvalid || wvalid || arvalid || bvalid || rvalid))
    else uvm_report_error("AXI_SVA", "a VALID is high during reset");
endinterface
