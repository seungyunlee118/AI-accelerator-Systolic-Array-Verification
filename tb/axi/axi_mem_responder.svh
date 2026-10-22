// Reactive AXI4 slave that plays memory for the DUT's DMA.
//
// Every clock edge it (1) records the handshakes that just happened, using the READY/VALID
// values it drove for that edge, then (2) decides the next READY/VALID values from the knobs
// in axi_mem_cfg, and (3) drives them through the clocking block.
//
// Reads: accepted bursts wait a random latency, then return beats in the order chosen by
// cfg.rd_order (in order, out of order across IDs, or interleaved beat by beat). Beats of the
// same ID always stay in order (AXI4 rule).
// Writes: AW and W are queued separately, beats are written byte by byte with WSTRB, and a B
// response is queued after each WLAST.
class axi_mem_responder extends uvm_component;
  `uvm_component_utils(axi_mem_responder)

  virtual axi_if vif;
  axi_mem_cfg    cfg;
  axi_mem_model  mem;

  typedef struct { bit [3:0] id; bit [31:0] addr; int beats; int sent; longint ready_cyc; } rd_burst_t;
  typedef struct { bit [31:0] addr; int beats; int got; } aw_t;
  typedef struct { bit [63:0] data; bit [7:0] strb; bit last; } w_t;

  protected rd_burst_t rd_q[$];
  protected aw_t       aw_q[$];
  protected w_t        w_q[$];
  protected bit [1:0]  b_q[$];
  protected longint    cyc;
  protected int        cur_id = -1;     // AXI_OUT_OF_ORDER: burst being returned

  // values currently on the bus (driven after the previous edge)
  protected bit        ar_rdy, aw_rdy, w_rdy, r_vld, b_vld;
  protected bit [3:0]  r_id;
  protected bit [63:0] r_data;
  protected bit [1:0]  r_resp, b_resp;
  protected bit        r_last;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual axi_if)::get(this, "", "axi_vif", vif))
      `uvm_fatal("NOVIF", "virtual axi_if 'axi_vif' not found in config_db")
  endfunction

  virtual task run_phase(uvm_phase phase);
    vif.arready <= 1'b0;  vif.awready <= 1'b0;  vif.wready <= 1'b0;
    vif.rvalid  <= 1'b0;  vif.bvalid  <= 1'b0;
    vif.rid <= '0;  vif.rdata <= '0;  vif.rresp <= '0;  vif.rlast <= 1'b0;
    vif.bid <= '0;  vif.bresp <= '0;
    // The memory shares the chip's asynchronous reset: drop every VALID/READY as soon as reset
    // is asserted, not at the next clock edge (the reset-quiet SVA checks this).
    fork
      forever begin
        @(negedge vif.rst_n);
        vif.arready <= 1'b0;  vif.awready <= 1'b0;  vif.wready <= 1'b0;
        vif.rvalid  <= 1'b0;  vif.bvalid  <= 1'b0;
      end
    join_none
    forever begin
      @(vif.slv_cb);
      cyc++;
      if (vif.rst_n !== 1'b1) begin
        rd_q.delete();  aw_q.delete();  w_q.delete();  b_q.delete();
        cur_id = -1;
        {ar_rdy, aw_rdy, w_rdy, r_vld, b_vld} = '0;
      end else begin
        sample_handshakes();
        choose_outputs();
      end
      drive();
    end
  endtask

  protected function bit pct(int unsigned p);
    return $urandom_range(0, 99) < p;
  endfunction

  // ------------------------------------------------------------ handshakes at this edge
  protected function void sample_handshakes();
    if (vif.slv_cb.arvalid && ar_rdy) begin
      rd_burst_t b;
      b.id        = vif.slv_cb.arid;
      b.addr      = vif.slv_cb.araddr;
      b.beats     = int'(vif.slv_cb.arlen) + 1;
      b.sent      = 0;
      b.ready_cyc = cyc + $urandom_range(cfg.lat_min, cfg.lat_max);
      rd_q.push_back(b);
    end

    if (r_vld && vif.slv_cb.rready) begin
      int idx[$];
      idx = rd_q.find_first_index(x) with (x.id == r_id);
      rd_q[idx[0]].sent++;
      if (r_last) begin
        rd_q.delete(idx[0]);
        if (cur_id == int'(r_id)) cur_id = -1;
      end
      r_vld = 1'b0;
    end

    if (vif.slv_cb.awvalid && aw_rdy) begin
      aw_t a;
      a.addr  = vif.slv_cb.awaddr;
      a.beats = int'(vif.slv_cb.awlen) + 1;
      a.got   = 0;
      aw_q.push_back(a);
    end

    if (vif.slv_cb.wvalid && w_rdy) begin
      w_t w;
      w.data = vif.slv_cb.wdata;
      w.strb = vif.slv_cb.wstrb;
      w.last = vif.slv_cb.wlast;
      w_q.push_back(w);
    end
    apply_writes();

    if (b_vld && vif.slv_cb.bready) begin
      void'(b_q.pop_front());
      b_vld = 1'b0;
    end
  endfunction

  // Write each W beat into memory once its AW is known.
  protected function void apply_writes();
    while (aw_q.size() > 0 && w_q.size() > 0) begin
      w_t        w;
      bit [31:0] base;
      w    = w_q.pop_front();
      base = aw_q[0].addr + 8 * aw_q[0].got;
      for (int b = 0; b < 8; b++)
        if (w.strb[b]) mem.dut_write_byte(base + b, w.data[8*b +: 8]);
      aw_q[0].got++;
      if (w.last) begin
        bit [1:0] resp;
        if (aw_q[0].got != aw_q[0].beats)
          `uvm_error("AXI_MEM", $sformatf("WLAST on beat %0d of a %0d-beat burst at %08h",
                                           aw_q[0].got, aw_q[0].beats, aw_q[0].addr))
        void'(aw_q.pop_front());
        resp = 2'b00;
        if (cfg.wr_err_at_resp != 0) begin
          cfg.wr_err_at_resp--;
          if (cfg.wr_err_at_resp == 0) resp = 2'b10;   // SLVERR
        end
        b_q.push_back(resp);
      end else if (aw_q[0].got == aw_q[0].beats) begin
        `uvm_error("AXI_MEM", $sformatf("burst at %08h has more beats than AWLEN and no WLAST", aw_q[0].addr))
      end
    end
  endfunction

  // ------------------------------------------------------------ next outputs
  protected function int pick_read();
    int cands[$];
    foreach (rd_q[i]) begin
      bit older_same_id = 0;
      for (int j = 0; j < i; j++) if (rd_q[j].id == rd_q[i].id) older_same_id = 1;
      if (!older_same_id && rd_q[i].ready_cyc <= cyc) cands.push_back(i);
    end
    if (cands.size() == 0) return -1;
    case (cfg.rd_order)
      AXI_IN_ORDER:     return (cands[0] == 0) ? 0 : -1;
      AXI_OUT_OF_ORDER: begin
        if (cur_id >= 0) foreach (rd_q[i]) if (int'(rd_q[i].id) == cur_id) return i;
        return cands[$urandom_range(0, cands.size() - 1)];
      end
      default:          return cands[$urandom_range(0, cands.size() - 1)];   // interleave
    endcase
  endfunction

  protected function void choose_outputs();
    ar_rdy = pct(cfg.arready_pct);
    aw_rdy = pct(cfg.awready_pct);
    w_rdy  = pct(cfg.wready_pct);

    if (!r_vld) begin                          // a beat on the bus stays until it is taken
      int p;
      p = pick_read();
      if (p >= 0 && pct(cfg.rvalid_pct)) begin
        r_vld  = 1'b1;
        r_id   = rd_q[p].id;
        r_data = mem.read_beat(rd_q[p].addr + 8 * rd_q[p].sent);
        r_last = (rd_q[p].sent == rd_q[p].beats - 1);
        r_resp = 2'b00;
        if (cfg.rd_err_at_beat != 0) begin
          cfg.rd_err_at_beat--;
          if (cfg.rd_err_at_beat == 0) r_resp = 2'b10;   // SLVERR
        end
        if (cfg.rd_order == AXI_OUT_OF_ORDER) cur_id = r_last ? -1 : int'(r_id);
      end
    end

    if (!b_vld && b_q.size() > 0 && pct(cfg.bvalid_pct)) begin
      b_vld  = 1'b1;
      b_resp = b_q[0];
    end
  endfunction

  protected task drive();
    vif.slv_cb.arready <= ar_rdy;
    vif.slv_cb.awready <= aw_rdy;
    vif.slv_cb.wready  <= w_rdy;
    vif.slv_cb.rvalid  <= r_vld;
    vif.slv_cb.rid     <= r_id;
    vif.slv_cb.rdata   <= r_data;
    vif.slv_cb.rresp   <= r_resp;
    vif.slv_cb.rlast   <= r_last;
    vif.slv_cb.bvalid  <= b_vld;
    vif.slv_cb.bid     <= 4'd0;
    vif.slv_cb.bresp   <= b_resp;
  endtask
endclass
