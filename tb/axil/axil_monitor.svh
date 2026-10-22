// AXI4-Lite monitor: rebuilds every completed access from the pins and broadcasts it.
// A write is complete at its B handshake (AW and W may arrive in either order before that);
// a read is complete at its R handshake. One outstanding access per direction (spec §3).
class axil_monitor extends uvm_monitor;
  `uvm_component_utils(axil_monitor)

  virtual axil_if vif;
  uvm_analysis_port #(axil_item) ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual axil_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "virtual axil_if 'vif' not found in config_db")
  endfunction

  virtual task run_phase(uvm_phase phase);
    bit [31:0] aw_q[$], ar_q[$], w_data_q[$];
    bit [3:0]  w_strb_q[$];
    axil_item  t;

    forever begin
      @(vif.mon_cb);
      if (vif.rst_n !== 1'b1) begin
        aw_q.delete(); ar_q.delete(); w_data_q.delete(); w_strb_q.delete();
        continue;
      end

      if (vif.mon_cb.awvalid && vif.mon_cb.awready) aw_q.push_back(vif.mon_cb.awaddr);
      if (vif.mon_cb.wvalid && vif.mon_cb.wready) begin
        w_data_q.push_back(vif.mon_cb.wdata);
        w_strb_q.push_back(vif.mon_cb.wstrb);
      end
      if (vif.mon_cb.bvalid && vif.mon_cb.bready) begin
        if (aw_q.size() == 0 || w_data_q.size() == 0) begin
          `uvm_error("AXIL_MON", "B response without a completed AW and W")
        end else begin
          t = axil_item::type_id::create("t");
          t.kind = AXIL_WRITE;
          t.addr = aw_q.pop_front();
          t.data = w_data_q.pop_front();
          t.strb = w_strb_q.pop_front();
          t.resp = vif.mon_cb.bresp;
          `uvm_info("AXIL_MON", t.convert2string(), UVM_MEDIUM)
          ap.write(t);
        end
      end

      if (vif.mon_cb.arvalid && vif.mon_cb.arready) ar_q.push_back(vif.mon_cb.araddr);
      if (vif.mon_cb.rvalid && vif.mon_cb.rready) begin
        if (ar_q.size() == 0) begin
          `uvm_error("AXIL_MON", "R data without a completed AR")
        end else begin
          t = axil_item::type_id::create("t");
          t.kind = AXIL_READ;
          t.addr = ar_q.pop_front();
          t.data = vif.mon_cb.rdata;
          t.resp = vif.mon_cb.rresp;
          `uvm_info("AXIL_MON", t.convert2string(), UVM_MEDIUM)
          ap.write(t);
        end
      end
    end
  endtask
endclass
