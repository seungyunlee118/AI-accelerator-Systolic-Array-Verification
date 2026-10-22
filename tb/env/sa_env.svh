// Full-chip environment: AXI4-Lite agent + RAL (CPU side), AXI4 memory agent (memory side),
// job scoreboard with the golden model, DMA checker on the AXI4 pins.
class sa_env extends uvm_env;
  `uvm_component_utils(sa_env)

  axil_agent                     axil;
  sa_gemm_csr                    regmodel;
  axil_reg_adapter               adapter;
  uvm_reg_predictor #(axil_item) predictor;
  axi_mem_agent                  axi;
  sa_scoreboard                  sb;
  sa_dma_checker                 dma_chk;
  sa_cov_db                      cov_db;
  sa_csr_cov                     csr_cov;   // CG-01
  sa_top_cov                     cov;       // CG-02 .. CG-09

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    axil = axil_agent::type_id::create("axil", this);
    axi  = axi_mem_agent::type_id::create("axi", this);
    sb   = sa_scoreboard::type_id::create("sb", this);
    dma_chk = sa_dma_checker::type_id::create("dma_chk", this);
    cov_db  = new();
    csr_cov = sa_csr_cov::type_id::create("csr_cov", this);
    cov     = sa_top_cov::type_id::create("cov", this);
    csr_cov.declare(cov_db);
    cov.declare(cov_db);

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

    sb.cov      = cov;
    cov.dma_chk = dma_chk;
    axi.mon.ap.connect(cov.axi_export);
    axil.mon.ap.connect(cov.axil_export);
    axil.mon.ap.connect(csr_cov.analysis_export);
  endfunction

  // +COV_DUMP=<file>: write this run's bin counts for sim/covmerge.py
  virtual function void report_phase(uvm_phase phase);
    string path;
    super.report_phase(phase);
    csr_cov.check();
    cov.check();
    if ($value$plusargs("COV_DUMP=%s", path)) cov_db.dump(path);
  endfunction
endclass
