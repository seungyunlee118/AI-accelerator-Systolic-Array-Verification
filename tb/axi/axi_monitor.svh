// Passive AXI4 monitor: rebuilds every complete burst and broadcasts it.
// Reads are matched by ID, so out-of-order and interleaved returns are handled. It also marks
// whether a read finished before an older one (out of order) or was interrupted by another ID's
// beat (interleaved), and how many reads were in flight when it was issued - the scenarios the
// vplan's coverage needs to prove happened.
class axi_monitor extends uvm_monitor;
  `uvm_component_utils(axi_monitor)

  virtual axi_if               vif;
  uvm_analysis_port #(axi_txn) ap;

  int unsigned n_reads, n_writes;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual axi_if)::get(this, "", "axi_vif", vif))
      `uvm_fatal("NOVIF", "virtual axi_if 'axi_vif' not found in config_db")
  endfunction

  virtual task run_phase(uvm_phase phase);
    axi_txn   rd_open [bit [3:0]];   // read bursts in flight, by ID
    bit [3:0] ar_order[$];           // IDs in the order their AR was accepted
    axi_txn   aw_q[$];               // write bursts waiting for data
    axi_txn   b_wait_q[$];           // write bursts waiting for their B
    axi_txn   t;
    int       last_rid = -1;
    bit       last_was_last = 1;

    forever begin
      @(vif.mon_cb);
      if (vif.rst_n !== 1'b1) begin
        rd_open.delete();  ar_order.delete();  aw_q.delete();  b_wait_q.delete();
        last_rid = -1;  last_was_last = 1;
        continue;
      end

      // ---- reads
      if (vif.mon_cb.arvalid && vif.mon_cb.arready) begin
        t = axi_txn::type_id::create("rd");
        t.dir  = AXI_READ;
        t.id   = vif.mon_cb.arid;
        t.addr = vif.mon_cb.araddr;
        t.len  = vif.mon_cb.arlen;
        t.outstanding = rd_open.num() + 1;
        rd_open[t.id] = t;
        ar_order.push_back(t.id);
      end
      if (vif.mon_cb.rvalid && vif.mon_cb.rready) begin
        bit [3:0] id = vif.mon_cb.rid;
        if (!rd_open.exists(id)) begin
          `uvm_error("AXI_MON", $sformatf("R beat for ID %0d with no read in flight", id))
        end else begin
          t = rd_open[id];
          if (last_rid >= 0 && last_rid != int'(id) && !last_was_last && rd_open.exists(4'(last_rid)))
            rd_open[4'(last_rid)].interleaved = 1;
          t.data.push_back(vif.mon_cb.rdata);
          if (vif.mon_cb.rresp > t.resp) t.resp = vif.mon_cb.rresp;
          if (vif.mon_cb.rlast) begin
            int pos[$];
            if (t.data.size() != int'(t.len) + 1)
              `uvm_error("AXI_MON", $sformatf("RLAST after %0d beats of a %0d-beat read", t.data.size(), t.len + 1))
            pos = ar_order.find_first_index(x) with (x == id);
            t.out_of_order = (pos[0] != 0);
            ar_order.delete(pos[0]);
            rd_open.delete(id);
            n_reads++;
            `uvm_info("AXI_MON", t.convert2string(), UVM_HIGH)
            ap.write(t);
          end
          last_rid      = int'(id);
          last_was_last = vif.mon_cb.rlast;
        end
      end

      // ---- writes
      if (vif.mon_cb.awvalid && vif.mon_cb.awready) begin
        t = axi_txn::type_id::create("wr");
        t.dir  = AXI_WRITE;
        t.id   = vif.mon_cb.awid;
        t.addr = vif.mon_cb.awaddr;
        t.len  = vif.mon_cb.awlen;
        aw_q.push_back(t);
      end
      if (vif.mon_cb.wvalid && vif.mon_cb.wready) begin
        if (aw_q.size() == 0) begin
          `uvm_error("AXI_MON", "W beat with no write address accepted yet")
        end else begin
          aw_q[0].data.push_back(vif.mon_cb.wdata);
          aw_q[0].strb.push_back(vif.mon_cb.wstrb);
          if (vif.mon_cb.wlast) b_wait_q.push_back(aw_q.pop_front());
        end
      end
      if (vif.mon_cb.bvalid && vif.mon_cb.bready) begin
        if (b_wait_q.size() == 0) begin
          `uvm_error("AXI_MON", "B response with no completed write burst")
        end else begin
          t = b_wait_q.pop_front();
          t.resp = vif.mon_cb.bresp;
          n_writes++;
          `uvm_info("AXI_MON", t.convert2string(), UVM_HIGH)
          ap.write(t);
        end
      end
    end
  endtask
endclass
