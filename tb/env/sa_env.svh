// Full-chip environment: AXI4-Lite agent + RAL (CPU side), AXI4 memory agent (memory side),
// job scoreboard with the golden model.
class sa_env extends uvm_env;
  `uvm_component_utils(sa_env)

  axil_agent                     axil;
  sa_gemm_csr                    regmodel;
  axil_reg_adapter               adapter;
  uvm_reg_predictor #(axil_item) predictor;
  axi_mem_agent                  axi;
  sa_scoreboard                  sb;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    axil = axil_agent::type_id::create("axil", this);
    axi  = axi_mem_agent::type_id::create("axi", this);
    sb   = sa_scoreboard::type_id::create("sb", this);

    regmodel = new("regmodel");
    regmodel.build();
    regmodel.lock_model();
    regmodel.reset();
    adapter   = axil_reg_adapter::type_id::create("adapter");
    predictor = uvm_reg_predictor#(axil_item)::type_id::create("predictor", this);
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    regmodel.default_map.set_sequencer(axil.sqr, adapter);
    regmodel.default_map.set_auto_predict(0);
    predictor.map     = regmodel.default_map;
    predictor.adapter = adapter;
    axil.mon.ap.connect(predictor.bus_in);

    sb.mem = axi.mem;
    axi.mon.ap.connect(sb.axi_export);
  endfunction
endclass
