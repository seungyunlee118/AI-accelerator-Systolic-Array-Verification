// One raw AXI4-Lite access with given address/data/strobes and random channel timing.
// Used by tests that need accesses RAL cannot make: unmapped or aliased addresses, partial
// strobes, and checking the raw response code.
class axil_single_seq extends uvm_sequence #(axil_item);
  `uvm_object_utils(axil_single_seq)

  axil_kind_e kind = AXIL_READ;
  bit [31:0]  addr;
  bit [31:0]  data;           // write data in, read data out
  bit [3:0]   strb = '1;
  bit [1:0]   resp;           // out

  function new(string name = "axil_single_seq");
    super.new(name);
  endfunction

  virtual task body();
    axil_item t = axil_item::type_id::create("t");
    start_item(t);
    if (!t.randomize() with { kind == local::kind; addr == local::addr;
                              data == local::data; strb == local::strb; })
      `uvm_fatal("AXIL_SEQ", "randomize failed")
    finish_item(t);
    data = t.data;
    resp = t.resp;
  endtask
endclass
