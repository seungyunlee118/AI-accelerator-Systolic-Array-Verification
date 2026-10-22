// DMA checker, watching the AXI4 pins every cycle (vplan CHK-04, CHK-10, and the bus side of
// CHK-09 and F-DP-06).
//   CHK-04  Every read burst lies inside one row window of A or B: [row start, row start + K
//           (or N)) rounded up to whole 8-byte beats. After a successful job, every beat of
//           every row was read.
//   CHK-10  After the first error response of a job (RRESP or BRESP != OKAY), no new AR or AW
//           starts. A VALID that was already waiting may still complete (AXI rule).
//   BUSY    falls only after every outstanding read and write burst has completed (spec §6
//           step 4, §8). A configuration-error job never raises BUSY and makes no AR or AW.
// Tests call start_job() before START and end_job() after the job's interrupt.
class sa_dma_checker extends uvm_component;
  `uvm_component_utils(sa_dma_checker)

  virtual axi_if    vif;
  virtual sa_sys_if sys;

  int unsigned n_ar, n_aw;                 // AR / AW handshakes since the start of the test
  int          rd_ot, wr_ot;               // bursts outstanding right now
  int          err_rd_ot;                  // reads outstanding when the job's first read error came

  protected sa_job       job;
  protected bit [3:0]    exp_err;
  protected bit          armed;            // a job was started and has not ended
  protected bit [31:0]   win_lo[$], win_hi[$];   // legal read windows, one per A/B row
  protected bit          need [bit [31:0]];      // beats the job must read
  protected bit          got  [bit [31:0]];      // beats it did read
  protected bit          err_resp_seen, busy_seen;
  protected int unsigned ar_job, aw_job;
  protected bit          ar_wait, aw_wait, busy_q;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual axi_if)::get(this, "", "axi_vif", vif))
      `uvm_fatal("NOVIF", "virtual axi_if 'axi_vif' not found in config_db")
    if (!uvm_config_db#(virtual sa_sys_if)::get(this, "", "sys_vif", sys))
      `uvm_fatal("NOVIF", "virtual sa_sys_if 'sys_vif' not found in config_db")
  endfunction

  function void start_job(sa_job j, bit [3:0] expected_err);
    job     = j;
    exp_err = expected_err;
    armed   = 1;
    win_lo.delete();  win_hi.delete();  need.delete();  got.delete();
    err_resp_seen = 0;  busy_seen = 0;  ar_job = 0;  aw_job = 0;  err_rd_ot = 0;
    if (j.cfg_err() != 0) return;
    for (int r = 0; r < j.m; r++) add_row(j.a_base + r * j.a_stride, j.k);
    for (int r = 0; r < j.k; r++) add_row(j.b_base + r * j.b_stride, j.n);
  endfunction

  protected function void add_row(bit [31:0] start, int unsigned len);
    bit [31:0] hi = start + 8 * ((len + 7) / 8);
    win_lo.push_back(start);
    win_hi.push_back(hi);
    for (bit [31:0] a = start; a < hi; a += 8) need[a] = 1;
  endfunction

  function void end_job();
    int missing = 0;
    if (!armed) return;
    armed = 0;
    if (exp_err == 1 || exp_err == 2) begin
      if (busy_seen) `uvm_error("DMA_CHK", "BUSY was set by a job with a configuration error")
      if (ar_job + aw_job != 0)
        `uvm_error("DMA_CHK", $sformatf("configuration error, but %0d AR and %0d AW were issued", ar_job, aw_job))
    end else if (exp_err == 0) begin
      foreach (need[a])
        if (!got.exists(a) && missing++ < 5)
          `uvm_error("DMA_CHK", $sformatf("needed beat %08h of A/B was never read", a))
    end
  endfunction

  protected function void check_ar(bit [31:0] addr, bit [7:0] len);
    bit [31:0] hi = addr + 8 * (int'(len) + 1);
    bit        inside_row = 0;
    foreach (win_lo[i])
      if (addr >= win_lo[i] && hi <= win_hi[i]) begin
        inside_row = 1;
        break;
      end
    if (!inside_row)
      `uvm_error("DMA_CHK", $sformatf("read burst %08h..%08h is not inside one row of A or B (%s)",
                                      addr, hi - 1, job.convert2string()))
    for (bit [31:0] a = addr; a < hi; a += 8) got[a] = 1;
  endfunction

  virtual task run_phase(uvm_phase phase);
    forever begin
      @(vif.mon_cb);
      if (vif.rst_n !== 1'b1) begin          // reset aborts the job and empties the bus
        rd_ot = 0;  wr_ot = 0;  ar_wait = 0;  aw_wait = 0;  busy_q = 0;  armed = 0;
        continue;
      end

      // BUSY may fall only when nothing is in flight (counts are from earlier edges)
      if (busy_q && !sys.mon_cb.busy && (rd_ot != 0 || wr_ot != 0))
        `uvm_error("DMA_CHK", $sformatf("BUSY fell with %0d read and %0d write bursts still outstanding", rd_ot, wr_ot))
      busy_q = sys.mon_cb.busy;
      if (busy_q && armed) busy_seen = 1;

      // CHK-10: a VALID that was not already waiting is a new request
      if (err_resp_seen && vif.mon_cb.arvalid && !ar_wait)
        `uvm_error("DMA_CHK", $sformatf("new read burst at %08h after an error response", vif.mon_cb.araddr))
      if (err_resp_seen && vif.mon_cb.awvalid && !aw_wait)
        `uvm_error("DMA_CHK", $sformatf("new write burst at %08h after an error response", vif.mon_cb.awaddr))
      ar_wait = vif.mon_cb.arvalid && !vif.mon_cb.arready;
      aw_wait = vif.mon_cb.awvalid && !vif.mon_cb.awready;

      if (vif.mon_cb.arvalid && vif.mon_cb.arready) begin
        n_ar++;  ar_job++;  rd_ot++;
        if (armed) check_ar(vif.mon_cb.araddr, vif.mon_cb.arlen);
      end
      if (vif.mon_cb.rvalid && vif.mon_cb.rready) begin
        if (vif.mon_cb.rresp != 2'b00 && !err_resp_seen) begin
          err_resp_seen = 1;
          err_rd_ot     = rd_ot;
        end
        if (vif.mon_cb.rlast) rd_ot--;
      end
      if (vif.mon_cb.awvalid && vif.mon_cb.awready) begin
        n_aw++;  aw_job++;  wr_ot++;
      end
      if (vif.mon_cb.bvalid && vif.mon_cb.bready) begin
        if (vif.mon_cb.bresp != 2'b00) err_resp_seen = 1;
        wr_ot--;
      end
    end
  endtask
endclass
