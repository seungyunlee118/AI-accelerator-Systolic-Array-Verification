// AXI4 memory agent: responder (active) + monitor, sharing one config and one memory model.
class axi_mem_agent extends uvm_agent;
  `uvm_component_utils(axi_mem_agent)

  axi_mem_cfg       cfg;
  axi_mem_model     mem;
  axi_mem_responder rsp;
  axi_monitor       mon;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    cfg = axi_mem_cfg::type_id::create("cfg");
    mem = axi_mem_model::type_id::create("mem");
    mon = axi_monitor::type_id::create("mon", this);
    rsp = axi_mem_responder::type_id::create("rsp", this);
    rsp.cfg = cfg;
    rsp.mem = mem;
  endfunction
endclass
