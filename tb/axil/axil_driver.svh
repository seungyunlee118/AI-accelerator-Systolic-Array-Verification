// AXI4-Lite master driver (plays the CPU).
//
// Fix carried over from the old AXI4-Lite project: a handshake can complete on the very first
// clock edge after VALID rises (a slave may hold READY high in advance). The old driver waited
// one extra edge before looking at READY, so with such a slave it held VALID one cycle too long
// and the same write happened twice. Here the first READY check is on that first edge.
class axil_driver extends uvm_driver #(axil_item);
  `uvm_component_utils(axil_driver)

  virtual axil_if vif;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual axil_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "virtual axil_if 'vif' not found in config_db")
  endfunction

  virtual task run_phase(uvm_phase phase);
    idle();
    wait (vif.rst_n === 1'b1);
    forever begin
      seq_item_port.get_next_item(req);
      @(vif.drv_cb);
      if (req.kind == AXIL_WRITE) drive_write(req);
      else                        drive_read(req);
      `uvm_info("AXIL_DRV", req.convert2string(), UVM_HIGH)
      seq_item_port.item_done();
    end
  endtask

  // All master outputs inactive (used at time 0, before the first clock edge).
  function void idle();
    vif.awvalid <= 1'b0;  vif.wvalid <= 1'b0;  vif.bready <= 1'b0;
    vif.arvalid <= 1'b0;  vif.rready <= 1'b0;
    vif.awaddr  <= '0;    vif.wdata  <= '0;    vif.wstrb  <= '0;   vif.araddr <= '0;
  endfunction

  task drive_write(axil_item t);
    fork
      begin : aw_channel
        repeat (t.aw_delay) @(vif.drv_cb);
        vif.drv_cb.awaddr  <= t.addr;
        vif.drv_cb.awvalid <= 1'b1;
        do @(vif.drv_cb); while (vif.drv_cb.awready !== 1'b1);   // handshake on this edge
        vif.drv_cb.awvalid <= 1'b0;
      end
      begin : w_channel
        repeat (t.w_delay) @(vif.drv_cb);
        vif.drv_cb.wdata  <= t.data;
        vif.drv_cb.wstrb  <= t.strb;
        vif.drv_cb.wvalid <= 1'b1;
        do @(vif.drv_cb); while (vif.drv_cb.wready !== 1'b1);
        vif.drv_cb.wvalid <= 1'b0;
      end
    join
    repeat (t.b_delay) @(vif.drv_cb);
    vif.drv_cb.bready <= 1'b1;
    do @(vif.drv_cb); while (vif.drv_cb.bvalid !== 1'b1);
    t.resp = vif.drv_cb.bresp;
    vif.drv_cb.bready <= 1'b0;
  endtask

  task drive_read(axil_item t);
    vif.drv_cb.araddr  <= t.addr;
    vif.drv_cb.arvalid <= 1'b1;
    do @(vif.drv_cb); while (vif.drv_cb.arready !== 1'b1);
    vif.drv_cb.arvalid <= 1'b0;
    repeat (t.r_delay) @(vif.drv_cb);
    vif.drv_cb.rready <= 1'b1;
    do @(vif.drv_cb); while (vif.drv_cb.rvalid !== 1'b1);
    t.data = vif.drv_cb.rdata;
    t.resp = vif.drv_cb.rresp;
    vif.drv_cb.rready <= 1'b0;
  endtask
endclass
