// Sparse byte-addressed memory behind the AXI4 responder.
// Tests fill A/B and paint sentinels through the backdoor functions; the responder applies
// the DUT's writes and records every byte address the DUT wrote (for containment checks).
class axi_mem_model extends uvm_object;
  `uvm_object_utils(axi_mem_model)

  protected bit [7:0] mem         [bit [31:0]];
  bit                 dut_written [bit [31:0]];   // byte addresses written by the DUT

  function new(string name = "axi_mem_model");
    super.new(name);
  endfunction

  function bit [7:0] read_byte(bit [31:0] a);
    return mem.exists(a) ? mem[a] : 8'h00;       // never-written memory reads as 0
  endfunction

  function void write_byte(bit [31:0] a, bit [7:0] d);
    mem[a] = d;
  endfunction

  // Called by the responder for every byte the DUT writes.
  function void dut_write_byte(bit [31:0] a, bit [7:0] d);
    mem[a]         = d;
    dut_written[a] = 1;
  endfunction

  function void clear_dut_written();
    dut_written.delete();
  endfunction

  function bit [63:0] read_beat(bit [31:0] a);   // a is 8-byte aligned
    for (int b = 0; b < 8; b++) read_beat[8*b +: 8] = read_byte(a + b);
  endfunction
endclass
