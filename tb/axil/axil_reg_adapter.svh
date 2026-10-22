// Translates between RAL register operations and AXI4-Lite items.
//
// Fix carried over from the old AXI4-Lite project: bus2reg must pass the bus response back
// to RAL. The old adapter always reported UVM_IS_OK, so RAL could never see an SLVERR.
class axil_reg_adapter extends uvm_reg_adapter;
  `uvm_object_utils(axil_reg_adapter)

  function new(string name = "axil_reg_adapter");
    super.new(name);
    supports_byte_enable = 1;   // WSTRB carries RAL byte enables
    provides_responses   = 0;   // the driver fills data/resp into the request itself
  endfunction

  virtual function uvm_sequence_item reg2bus(const ref uvm_reg_bus_op rw);
    axil_item t = axil_item::type_id::create("t");
    t.kind = (rw.kind == UVM_WRITE) ? AXIL_WRITE : AXIL_READ;
    t.addr = rw.addr;
    t.data = rw.data;
    t.strb = rw.byte_en[3:0];
    return t;
  endfunction

  virtual function void bus2reg(uvm_sequence_item bus_item, ref uvm_reg_bus_op rw);
    axil_item t;
    if (!$cast(t, bus_item)) begin
      `uvm_fatal("AXIL_ADAPTER", "bus2reg: item is not an axil_item")
      return;
    end
    rw.kind    = (t.kind == AXIL_WRITE) ? UVM_WRITE : UVM_READ;
    rw.addr    = t.addr;
    rw.data    = t.data;
    rw.byte_en = t.strb;
    rw.n_bits  = 32;
    rw.status  = (t.resp == 2'b00) ? UVM_IS_OK : UVM_NOT_OK;
  endfunction
endclass
