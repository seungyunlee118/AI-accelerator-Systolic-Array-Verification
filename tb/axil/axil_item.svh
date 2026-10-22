// One AXI4-Lite access (read or write) plus timing knobs for the driver.
typedef enum bit {AXIL_READ, AXIL_WRITE} axil_kind_e;

class axil_item extends uvm_sequence_item;
  rand axil_kind_e  kind;
  rand bit [31:0]   addr;
  rand bit [31:0]   data;       // write data, or read data filled in by the driver/monitor
  rand bit [3:0]    strb;       // write byte enables
  bit      [1:0]    resp;       // BRESP / RRESP returned by the DUT

  // Timing knobs, in clock cycles. aw_delay vs w_delay decides whether AW or W goes first.
  rand int unsigned aw_delay, w_delay, b_delay, r_delay;

  constraint c_delays {
    aw_delay inside {[0:3]};
    w_delay  inside {[0:3]};
    b_delay  inside {[0:3]};
    r_delay  inside {[0:3]};
  }

  `uvm_object_utils(axil_item)

  function new(string name = "axil_item");
    super.new(name);
    strb = '1;
  endfunction

  virtual function string convert2string();
    if (kind == AXIL_WRITE)
      return $sformatf("WRITE addr=%08h data=%08h strb=%b resp=%0d", addr, data, strb, resp);
    return $sformatf("READ  addr=%08h data=%08h resp=%0d", addr, data, resp);
  endfunction

  virtual function void do_copy(uvm_object rhs);
    axil_item t;
    super.do_copy(rhs);
    if (!$cast(t, rhs)) `uvm_fatal("AXIL_ITEM", "do_copy: wrong type")
    kind = t.kind;  addr = t.addr;  data = t.data;  strb = t.strb;  resp = t.resp;
    aw_delay = t.aw_delay;  w_delay = t.w_delay;  b_delay = t.b_delay;  r_delay = t.r_delay;
  endfunction
endclass
