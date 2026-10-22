// AXI4-Lite agent: monitor always; sequencer and driver only when active.
class axil_agent extends uvm_agent;
  `uvm_component_utils(axil_agent)

  uvm_sequencer #(axil_item) sqr;
  axil_driver                drv;
  axil_monitor               mon;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    mon = axil_monitor::type_id::create("mon", this);
    if (get_is_active() == UVM_ACTIVE) begin
      sqr = uvm_sequencer#(axil_item)::type_id::create("sqr", this);
      drv = axil_driver::type_id::create("drv", this);
    end
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (get_is_active() == UVM_ACTIVE)
      drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass
