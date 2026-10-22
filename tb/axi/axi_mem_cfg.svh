// Knobs of the AXI4 memory responder. Tests change them between jobs.
typedef enum {AXI_IN_ORDER, AXI_OUT_OF_ORDER, AXI_INTERLEAVE} axi_rd_order_e;

class axi_mem_cfg extends uvm_object;
  `uvm_object_utils(axi_mem_cfg)

  // read data may start lat_min..lat_max cycles after a read burst is accepted
  int unsigned   lat_min = 0;
  int unsigned   lat_max = 8;

  // how often (percent of cycles) each ready/valid driven by memory is high
  int unsigned   arready_pct = 80;
  int unsigned   awready_pct = 80;
  int unsigned   wready_pct  = 80;
  int unsigned   rvalid_pct  = 80;
  int unsigned   bvalid_pct  = 80;

  // order in which outstanding read bursts return their data
  axi_rd_order_e rd_order = AXI_IN_ORDER;

  // one-shot error injection: the Nth R beat / Nth B response from now gets SLVERR
  // (counted from 1); 0 = off. The responder clears the knob once it fires.
  int unsigned   rd_err_at_beat = 0;
  int unsigned   wr_err_at_resp = 0;

  function new(string name = "axi_mem_cfg");
    super.new(name);
  endfunction

  function string convert2string();
    return $sformatf("order=%s lat=%0d..%0d ready%%(ar/aw/w)=%0d/%0d/%0d valid%%(r/b)=%0d/%0d",
                     rd_order.name(), lat_min, lat_max, arready_pct, awready_pct, wready_pct,
                     rvalid_pct, bvalid_pct);
  endfunction
endclass
